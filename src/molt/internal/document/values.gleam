import gleam/bool
import gleam/list
import gleam/option.{Some}
import gleam/result
import greenwood.{type Element, Node, NodeElement as N}
import greenwood/zipper
import molt/cst
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/document/arrays
import molt/internal/document/index.{Fresh, Hit, Miss, RootDottedKey}
import molt/internal/document/primitives
import molt/internal/document/remove
import molt/internal/document/structure
import molt/internal/path
import molt/internal/utils
import molt/ops
import molt/types.{type Document, type Path, type TomlKind, KeySegment}
import molt/value.{type Value}

pub fn set(
  doc doc: Document,
  path p: String,
  value val: Value,
) -> Result(Document, MoltError) {
  let type_of = value.type_of(val)

  use <- bool.guard(
    type_of == "invalid",
    return: Error(error.InvalidTomlValue(path: p, text: value.invalid_text(val))),
  )

  // `Set` writes value nodes only. A section-table or array of tables `Value`
  // encodes header intent, not a value: reject it rather than silently
  // creating a header (Place's job) or coercing it inline (the `as_*` coercions).
  use <- bool.guard(
    type_of == "table" || type_of == "array_of_tables",
    return: Error(error.TypeMismatch(
      path: Some(p),
      expected: "scalar, array, or inline-table value",
      got: type_of,
    )),
  )

  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexScalarValue(..))
    | Hit(_, types.IndexArrayValue(..))
    | Hit(_, types.IndexInlineTableValue(..)) ->
      primitives.cursor_replace_value(
        doc:,
        idx:,
        path: segments,
        new_value: value.to_cst(val),
      )

    Hit(_, types.IndexImplicitTable(..)) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "scalar or array value",
        got: "implicit table",
      ))

    Hit(_, types.IndexTable(..)) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "scalar or array value",
        got: "table",
      ))

    Hit(_, types.IndexArrayOfTables(..)) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "scalar or array value (use an index to select an entry)",
        got: "array of tables",
      ))

    Hit(_, types.IndexArrayOfTablesEntry(..)) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "a key within the array entry",
        got: "array of tables entry",
      ))

    Miss(ancestor_path:, ancestor:, ..) -> {
      use site <- result.try(index.insertion_site(
        idx:,
        ancestor_path:,
        ancestor:,
        full_path: segments,
      ))
      primitives.write_at_site(doc:, idx:, site:, full_path: segments, val:)
    }

    Fresh(_) ->
      primitives.write_at_site(
        doc:,
        idx:,
        site: RootDottedKey(segments),
        full_path: segments,
        val:,
      )
  }
}

pub fn replace(
  doc doc: Document,
  path p: String,
  value val: Value,
) -> Result(Document, MoltError) {
  use <- bool.guard(
    value.type_of(val) == "invalid",
    return: Error(error.InvalidTomlValue(path: p, text: value.invalid_text(val))),
  )
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  use doc2 <- result.try(case index.resolve(idx, segments) {
    Hit(..) -> remove.prune(doc:, idx:, path: segments)
    Miss(..) | Fresh(_) -> Ok(doc)
  })
  case value.type_of(val) {
    "table" -> {
      // `doc2` has been pruned, so `path` is absent: ensure the table, then
      // populate it.
      use entries <- result.try(value.table_to_list(val))
      use doc3 <- result.try(structure.ensure_exists(
        doc: doc2,
        path: p,
        kind: types.Table,
      ))
      structure.merge_values(
        doc: doc3,
        path: p,
        entries:,
        on_conflict: ops.OnConflictError,
      )
    }
    "array_of_tables" -> {
      use items <- result.try(value.array_to_list(val))
      replace_array_of_tables(doc: doc2, path: p, items:)
    }
    _ -> set(doc: doc2, path: p, value: val)
  }
}

/// Build `[[path]]` with one entry per table-like item. The first item fills the
/// entry created by `ensure_exists`; the rest are appended. An empty value adds
/// nothing (matching the old per-item fold over `[]`). `path` is assumed absent
/// (the `Place` caller prunes it first).
fn replace_array_of_tables(
  doc doc: Document,
  path p: String,
  items items: List(Value),
) -> Result(Document, MoltError) {
  case items {
    [] -> Ok(doc)
    [first, ..rest] -> {
      use first_entries <- result.try(value.table_to_list(first))
      use d0 <- result.try(structure.ensure_exists(
        doc:,
        path: p,
        kind: types.ArrayOfTables,
      ))
      use d1 <- result.try(structure.merge_values(
        doc: d0,
        path: p <> "[0]",
        entries: first_entries,
        on_conflict: ops.OnConflictError,
      ))
      list.try_fold(rest, d1, fn(d, item) {
        arrays.append(doc: d, path: p, value: item)
      })
    }
  }
}

pub fn insert_key(
  doc doc: Document,
  path p: String,
  before before: String,
  key key: String,
  value val: Value,
) -> Result(Document, MoltError) {
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexTable(..)) | Hit(_, types.IndexArrayOfTablesEntry(..)) -> {
      let kv =
        builder.build_kv_node(
          key: utils.quote_key(key),
          value: value.to_cst(val),
        )
      // The op layer is intentionally forgiving: a missing `before` anchor
      // falls back to appending rather than failing: a benign positioning
      // miss must not halt a `run` batch. The `cst.insert_kv` primitive stays
      // strict; we recover only the not-found-anchor case, so a genuine key
      // collision still surfaces as an error.
      use new_tree <- result.try(
        case
          cst.insert_kv(
            node: doc.tree,
            into: segments,
            kv:,
            at: cst.BeforeKey(before),
          )
        {
          Error(error.NotFound(..)) ->
            cst.insert_kv(node: doc.tree, into: segments, kv:, at: cst.KvAtEnd)
          other -> other
        },
      )
      let full_path = list.append(segments, [KeySegment(key)])
      let idx_key = index.path_to_index_key(full_path)
      let entry = index.entry_for_value(val, container: segments)
      let idx = index.insert_entry(idx:, key: idx_key, entry:)
      Ok(primitives.patch(doc:, tree: new_tree, idx:))
    }

    Hit(_, types.IndexImplicitTable(..)) ->
      insert_key_in_implicit(
        doc:,
        idx:,
        container: segments,
        before:,
        key:,
        val:,
      )

    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "table or array of tables entry",
        got: utils.index_entry_to_string(entry),
      ))

    Miss(..) | Fresh(_) -> Error(error.not_found(p))
  }
}

pub fn update(
  doc doc: Document,
  path p: String,
  with transform: fn(Value) -> Result(Value, MoltError),
) -> Result(Document, MoltError) {
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexScalarValue(..))
    | Hit(_, types.IndexArrayValue(..))
    | Hit(_, types.IndexInlineTableValue(..)) ->
      cursor_transform_value(doc:, idx:, path: segments, with: transform)

    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "scalar, array, or inline table",
        got: utils.index_entry_to_string(entry),
      ))

    Miss(ancestor_path: _, ancestor:, ..) ->
      case ancestor {
        types.IndexScalarValue(..)
        | types.IndexArrayValue(..)
        | types.IndexInlineTableValue(..) ->
          cursor_transform_value(doc:, idx:, path: segments, with: transform)
        _ -> Error(error.not_found(p))
      }

    Fresh(_) -> Error(error.not_found(p))
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn cursor_transform_value(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  path segments: Path,
  with transform: fn(Value) -> Result(Value, MoltError),
) -> Result(Document, MoltError) {
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: segments)
    |> result.replace_error(error.not_found_path(segments)),
  )
  let current = value.from_cst(cursor.focus)
  use new_val <- result.try(transform(current))
  let path_str = path.to_string(segments)
  let new_val_type = value.type_of(new_val)
  use <- bool.guard(
    new_val_type == "table" || new_val_type == "array_of_tables",
    return: Error(error.TypeMismatch(
      path: Some(path_str),
      expected: "scalar or inline value",
      got: new_val_type,
    )),
  )
  use <- bool.guard(
    new_val_type == "invalid",
    return: Error(error.InvalidTomlValue(
      path: path_str,
      text: value.invalid_text(new_val),
    )),
  )
  let new_node = case cursor.focus.kind {
    types.ArrayElement ->
      primitives.rebuild_array_element(cursor.focus, value.to_cst(new_val))
    _ -> primitives.rebuild_kv_value(cursor.focus, value.to_cst(new_val))
  }
  zipper.set_focus(zipper: cursor, node: new_node)
  |> zipper.unzip
  |> primitives.patch(doc:, idx:)
  |> Ok
}

fn insert_key_in_implicit(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  container container: Path,
  before before: String,
  key key: String,
  val val: Value,
) -> Result(Document, MoltError) {
  case path.split_at_last_index(container) {
    // No index: insert among the document's root key-values (existing path).
    Error(Nil) -> {
      let before_keys =
        path.path_to_table_header(list.append(container, [KeySegment(before)]))
      let new_key_path = list.append(container, [KeySegment(key)])
      let kv =
        builder.build_kv_from_path(
          key: key_segment_names(new_key_path),
          value: value.to_cst(val),
        )
      let new_children =
        insert_before_root_kv_with_path(
          children: doc.tree.children,
          target_key_path: before_keys,
          new_el: N(kv),
        )
      let new_tree = Node(..doc.tree, children: new_children)
      let idx_key = index.path_to_index_key(new_key_path)
      let entry = index.entry_for_value(val, container:)
      let idx = index.insert_entry(idx:, key: idx_key, entry:)
      Ok(primitives.patch(doc:, tree: new_tree, idx:))
    }

    // Indexed: insert into the implicit table within the array of tables entry,
    // relative to that entry's subtree, then rebuild.
    Ok(#(entry_path, rel_container)) -> {
      let before_keys =
        path.path_to_table_header(
          list.append(rel_container, [KeySegment(before)]),
        )
      let rel_key_path = list.append(rel_container, [KeySegment(key)])
      let kv =
        builder.build_kv_from_path(
          key: key_segment_names(rel_key_path),
          value: value.to_cst(val),
        )
      use cursor <- result.try(
        query.get_cursor(node: doc.tree, path: entry_path)
        |> result.replace_error(error.not_found_path(container)),
      )
      let entry = cursor.focus
      let new_entry =
        Node(
          ..entry,
          children: insert_before_root_kv_with_path(
            children: entry.children,
            target_key_path: before_keys,
            new_el: N(kv),
          ),
        )
      let new_tree =
        zipper.set_focus(zipper: cursor, node: new_entry) |> zipper.unzip
      Ok(primitives.rebuild(doc:, tree: new_tree))
    }
  }
}

fn key_segment_names(path: Path) -> List(String) {
  list.filter_map(path, fn(seg) {
    case seg {
      KeySegment(name) -> Ok(utils.quote_key(name))
      _ -> Error(Nil)
    }
  })
}

fn insert_before_root_kv_with_path(
  children children: List(Element(TomlKind)),
  target_key_path target_key_path: List(String),
  new_el new_el: Element(TomlKind),
) -> List(Element(TomlKind)) {
  case children {
    [] -> [new_el]
    [N(n), ..rest] if n.kind == types.KeyValue ->
      case elements.key_path(n.children) {
        Some(kp) if kp == target_key_path -> [new_el, N(n), ..rest]
        _ -> [
          N(n),
          ..insert_before_root_kv_with_path(
            children: rest,
            target_key_path:,
            new_el:,
          )
        ]
      }
    [el, ..rest] -> [
      el,
      ..insert_before_root_kv_with_path(
        children: rest,
        target_key_path:,
        new_el:,
      )
    ]
  }
}
