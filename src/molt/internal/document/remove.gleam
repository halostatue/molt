import gleam/list
import gleam/option.{None, Some}
import gleam/result
import greenwood.{type Element, type Node, Bare, Node, NodeElement as N, Trivia}
import greenwood/zipper
import molt/cst
import molt/error.{type MoltError}
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/document/index
import molt/internal/document/primitives
import molt/internal/path
import molt/types.{type Document, type IndexKey, type Path, type TomlKind}

pub fn delete(
  doc doc: Document,
  path p: String,
) -> Result(Document, MoltError) {
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  prune(doc:, idx:, path: segments)
}

pub fn prune(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  path segments: Path,
) -> Result(Document, MoltError) {
  // Resolve negative AoT indices for dispatch; the original `segments` are kept
  // for navigation (structural, already negative-aware) and error reporting.
  let lookup = index.resolve_negative_indices(idx:, path: segments)
  let key = index.path_to_index_key(lookup)
  case index.get(idx, key) {
    Ok(entry) -> remove_existing(doc:, idx:, path: segments, entry:)
    Error(Nil) -> remove_missing(doc:, idx:, key:, path: segments)
  }
}

fn remove_existing(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  path segments: Path,
  entry entry: types.IndexEntry,
) -> Result(Document, MoltError) {
  let key = index.path_to_index_key(segments)
  let idx = index.remove_subtree(idx:, key:)
  case entry {
    types.IndexScalarValue(..)
    | types.IndexArrayValue(..)
    | types.IndexInlineTableValue(..)
    | types.IndexTable(..) ->
      remove_value(doc:, path: segments, strip_first_blank: False)

    types.IndexArrayOfTablesEntry(..) ->
      remove_value(doc:, path: segments, strip_first_blank: True)

    types.IndexImplicitTable(..) ->
      remove_implicit_table(doc:, idx:, path: segments)

    types.IndexArrayOfTables(..) ->
      remove_existing_array_of_tables(doc:, idx:, path: segments)
  }
}

fn remove_existing_array_of_tables(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  path segments: Path,
) -> Result(Document, MoltError) {
  case path.contains_index(segments) {
    // Unindexed: remove every matching header (the whole family).
    False -> {
      let target_path = path.path_to_table_header(segments)
      let new_tree =
        greenwood.remove_children(in: doc.tree, where: fn(el) {
          case el {
            N(n) if n.kind == types.ArrayOfTables ->
              elements.extract_key_segments(n.children) == target_path
            _ -> False
          }
        })
      Ok(primitives.patch(doc:, tree: new_tree, idx:))
    }

    // Indexed (e.g. `x[0].a`, `q[0].x[1].a`): a nested array of tables family
    // lives as top-level sibling headers scoped *positionally* between parent
    // entry headers, not inside the entry node. Remove only those belonging to
    // the selected (possibly deeply nested) parent entries, then rebuild.
    True -> {
      let norm = index.resolve_negative_indices(idx:, path: segments)
      let scopes = index_scopes(norm)
      let target = path.path_to_table_header(norm)
      let new_children =
        remove_scoped_family(
          children: doc.tree.children,
          scopes:,
          target:,
          counters: list.map(scopes, fn(_) { -1 }),
          acc: [],
        )
      Ok(primitives.rebuild(
        doc:,
        tree: Node(..doc.tree, children: new_children),
      ))
    }
  }
}

fn remove_value(
  doc doc: Document,
  path segments: Path,
  strip_first_blank strip_first_blank: Bool,
) -> Result(Document, MoltError) {
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: segments)
    |> result.replace_error(error.not_found_path(segments)),
  )

  // When removing the first AoT entry (no preceding Node sibling), the right
  // sibling carries an orphaned inter-entry separator newline in its leading
  // trivia. Detect this now, before the zipper moves.
  let is_first_with_right_sibling = case strip_first_blank, cursor.crumbs {
    True, [crumb, ..] ->
      !list.any(crumb.left, fn(el) {
        case el {
          N(_) -> True
          _ -> False
        }
      })
      && list.any(crumb.right, fn(el) {
        case el {
          N(_) -> True
          _ -> False
        }
      })
    _, _ -> False
  }

  // Rebuild the index from the mutated tree: removing an array of tables entry
  // renumbers its siblings and shifts the family count, which a patch can't
  // express cheaply or safely.
  case zipper.delete(cursor) {
    Some(cursor) -> {
      // Strip the orphaned leading separator newline(s) from the new first
      // entry when the deleted node was first at its level.
      let cursor = case is_first_with_right_sibling {
        False -> cursor
        True ->
          zipper.set_focus(
            zipper: cursor,
            node: drop_leading_newlines(cursor.focus),
          )
      }
      Ok(primitives.rebuild(doc:, tree: zipper.unzip(cursor)))
    }
    None -> {
      use new_tree <- result.try(cst.delete(node: doc.tree, path: segments))
      Ok(primitives.rebuild(doc:, tree: new_tree))
    }
  }
}

/// Drop leading Newline tokens from a node's leading trivia. Used to remove
/// the orphaned inter-entry separator when the first AoT entry is deleted and
/// its right sibling becomes the new document-leading node.
fn drop_leading_newlines(node: Node(TomlKind)) -> Node(TomlKind) {
  case node.trivia {
    Bare -> node
    Trivia(leading:, trailing:) -> {
      let stripped = list.drop_while(leading, fn(t) { t.kind == types.Newline })
      Node(..node, trivia: Trivia(leading: stripped, trailing:))
    }
  }
}

fn remove_missing(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  key key: IndexKey,
  path segments: Path,
) -> Result(Document, MoltError) {
  case index.find_deepest_ancestor_entry(idx, key) {
    Ok(types.IndexScalarValue(..))
    | Ok(types.IndexArrayValue(..))
    | Ok(types.IndexInlineTableValue(..)) -> {
      use cursor <- result.try(
        query.get_cursor(node: doc.tree, path: segments)
        |> result.replace_error(error.not_found_path(segments)),
      )

      use cursor <- result.try(
        zipper.delete(cursor)
        |> option.to_result(error.not_found_path(segments)),
      )

      zipper.unzip(cursor)
      |> primitives.patch(doc:, idx:)
      |> Ok
    }
    _ -> Error(error.not_found_path(segments))
  }
}

fn remove_implicit_table(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  path segments: Path,
) -> Result(Document, MoltError) {
  case path.split_at_last_index(segments) {
    // No index segment: remove the implicit table at the document root.
    Error(Nil) -> {
      let prefix = path.path_to_table_header(segments)
      let new_tree =
        greenwood.remove_children(in: doc.tree, where: under_prefix(prefix))
      let key = index.path_to_index_key(segments)
      let idx = index.prune_empty_implicit_ancestors(idx:, key:)
      Ok(primitives.patch(doc:, tree: new_tree, idx:))
    }

    // Indexed: descend into the array of tables entry, then remove the implicit
    // table within that entry's subtree. Rebuild, since entry contents shift.
    Ok(#(entry_path, rel_segments)) -> {
      let prefix = path.path_to_table_header(rel_segments)
      use cursor <- result.try(
        query.get_cursor(node: doc.tree, path: entry_path)
        |> result.replace_error(error.not_found_path(segments)),
      )
      let new_entry =
        greenwood.remove_children(in: cursor.focus, where: under_prefix(prefix))
      let new_tree =
        zipper.set_focus(zipper: cursor, node: new_entry) |> zipper.unzip
      Ok(primitives.rebuild(doc:, tree: new_tree))
    }
  }
}

/// Predicate matching tables / array of tables headers and key-values whose key
/// path begins with `prefix` (used to remove an implicit table's nodes).
fn under_prefix(prefix: List(String)) -> fn(Element(TomlKind)) -> Bool {
  fn(el) {
    case el {
      N(n) if n.kind == types.Table || n.kind == types.ArrayOfTables ->
        list.take(
          elements.extract_key_segments(n.children),
          list.length(prefix),
        )
        == prefix
      N(n) if n.kind == types.KeyValue -> is_kv_under_prefix(n, prefix)
      _ -> False
    }
  }
}

/// Decompose an indexed path into its per-level `#(family-header, entry-index)`
/// scopes, e.g. `q[0].x[1].a` -> `[#(["q"], 0), #(["q", "x"], 1)]`. Each pair
/// says "within the entry at this index of this family".
fn index_scopes(segments: Path) -> List(#(List(String), Int)) {
  do_index_scopes(remaining: segments, keys: [], acc: [])
}

fn do_index_scopes(
  remaining remaining: Path,
  keys keys: List(String),
  acc acc: List(#(List(String), Int)),
) -> List(#(List(String), Int)) {
  case remaining {
    [] -> list.reverse(acc)
    [types.KeySegment(k), ..rest] ->
      do_index_scopes(remaining: rest, keys: list.append(keys, [k]), acc:)
    [types.IndexSegment(i), ..rest] ->
      do_index_scopes(remaining: rest, keys:, acc: [#(keys, i), ..acc])
  }
}

/// Remove, from top-level `children`, the array of tables headers matching
/// `target` that belong to the (possibly deeply nested) parent entries named by
/// `scopes`. Scoping is positional: `counters` tracks the current entry index of
/// each scope family as we walk; a parent-family header advances its counter and
/// resets deeper ones (a new parent entry restarts its children's numbering).
fn remove_scoped_family(
  children children: List(Element(TomlKind)),
  scopes scopes: List(#(List(String), Int)),
  target target: List(String),
  counters counters: List(Int),
  acc acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> list.reverse(acc)
    [N(n), ..rest] if n.kind == types.ArrayOfTables || n.kind == types.Table -> {
      let kp = elements.extract_key_segments(n.children)
      let counters = bump_counters(scopes:, counters:, kp:)
      let drop =
        list.take(kp, list.length(target)) == target
        && counters_match(scopes, counters)
      let acc = case drop {
        True -> acc
        False -> [N(n), ..acc]
      }
      remove_scoped_family(children: rest, scopes:, target:, counters:, acc:)
    }
    [el, ..rest] ->
      remove_scoped_family(children: rest, scopes:, target:, counters:, acc: [
        el,
        ..acc
      ])
  }
}

/// Advance the counter for the scope level whose family equals `kp`, resetting
/// all deeper levels to -1. Levels not equal to `kp` are unchanged.
fn bump_counters(
  scopes scopes: List(#(List(String), Int)),
  counters counters: List(Int),
  kp kp: List(String),
) -> List(Int) {
  case scopes, counters {
    [#(family, _), ..s_rest], [c, ..c_rest] ->
      case family == kp {
        True -> [c + 1, ..list.map(c_rest, fn(_) { -1 })]
        False -> [c, ..bump_counters(scopes: s_rest, counters: c_rest, kp:)]
      }
    _, _ -> counters
  }
}

fn counters_match(
  scopes: List(#(List(String), Int)),
  counters: List(Int),
) -> Bool {
  case scopes, counters {
    [], [] -> True
    [#(_, idx), ..s], [c, ..cs] -> idx == c && counters_match(s, cs)
    _, _ -> False
  }
}

fn is_kv_under_prefix(kv: Node(TomlKind), prefix: List(String)) -> Bool {
  case elements.key_path(kv.children) {
    Some(key_parts) -> list.take(key_parts, list.length(prefix)) == prefix
    None -> False
  }
}
