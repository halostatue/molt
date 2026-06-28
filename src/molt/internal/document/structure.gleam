import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import greenwood/zipper
import molt/cst
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/document/index.{Fresh, Hit, Miss}
import molt/internal/document/primitives
import molt/internal/path
import molt/internal/utils
import molt/internal/validate
import molt/ops
import molt/types.{
  type Document, type Path, type TomlKind, IndexSegment, KeySegment,
}
import molt/value.{type Value}

// ---------------------------------------------------------------------------
// EnsureExists / MergeValues
// ---------------------------------------------------------------------------

/// Idempotently ensure a `Table` / `ArrayOfTables` structure exists at `path`.
/// The index resolve gate below catches every type-incompatible case BEFORE
/// delegating to `cst.ensure`, because `cst.ensure` no-ops on any resolvable
/// cursor without checking the occupant's kind.
pub fn ensure_exists(
  doc doc: Document,
  path p: String,
  kind kind: TomlKind,
) -> Result(Document, MoltError) {
  use <- bool.guard(
    kind != types.Table && kind != types.ArrayOfTables,
    return: Error(error.TypeMismatch(
      path: Some(p),
      expected: "Table or ArrayOfTables kind",
      got: utils.toml_kind(kind),
    )),
  )
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  let mismatch = fn(got: String) {
    Error(error.TypeMismatch(
      path: Some(p),
      expected: utils.toml_kind(kind),
      got:,
    ))
  }
  case index.resolve(idx, segments), kind {
    // Implicit table -> concretize. Routed through the promotion primitive (not
    // bare `cst.ensure`) so a DOTTED-implicit table's value descendants are
    // rehomed into the new `[a.b]` section; `cst.ensure` alone would emit the
    // header alongside the dotted key, producing a DuplicateTable.
    Hit(_, types.IndexImplicitTable(..)), types.Table ->
      promote_implicit_to_concrete(doc:, path: segments)

    // Already the right structure: idempotent no-op.
    Hit(_, types.IndexTable(..)), types.Table
    | Hit(_, types.IndexArrayOfTablesEntry(..)), types.Table
    | Hit(_, types.IndexArrayOfTables(..)), types.ArrayOfTables
    -> Ok(doc)

    // Any other exact occupant is incompatible.
    Hit(_, entry), _ -> mismatch(utils.index_entry_to_string(entry))

    Miss(ancestor:, tail:, ..), _ ->
      case ancestor {
        types.IndexScalarValue(..)
        | types.IndexArrayValue(..)
        | types.IndexInlineTableValue(..) ->
          mismatch(utils.index_entry_to_string(ancestor))
        _ ->
          case path.contains_index(tail) {
            True -> Error(error.not_found(p))
            False -> do_build(doc:, segments:, kind:)
          }
      }

    Fresh(_), _ ->
      case path.contains_index(segments) {
        True -> Error(error.not_found(p))
        False -> do_build(doc:, segments:, kind:)
      }
  }
}

/// Build a fresh `[path]` / `[[path]]` header and insert it (ordered before any
/// descendant headers). Index segments in `segments` are stripped for the
/// emitted header: `[a.b[0].c]` is not valid TOML; the header is `[a.b.c]`,
/// which TOML scopes to the last AoT entry. `cst.ensure` cannot be used here:
/// its `collect_key_prefix` stops at the first index segment, so it would build
/// `[a.b]` instead of `[a.b.c]`.
fn do_build(
  doc doc: Document,
  segments segments: Path,
  kind kind: TomlKind,
) -> Result(Document, MoltError) {
  let key_only = path.path_to_table_header(segments)
  let header = case kind {
    types.ArrayOfTables -> builder.build_empty_array_of_tables(key_only)
    _ -> builder.build_empty_table(key_only)
  }
  cst.insert_table_node(node: doc.tree, table: header)
  |> result.map(primitives.rebuild(doc:, tree: _))
}

/// Transfer relative-path `entries` into the concrete table at `path`. Does NOT
/// create or concretize `path`: the caller uses `ensure_exists` first. Atomic:
/// any entry error abandons the batch.
pub fn merge_values(
  doc doc: Document,
  path p: String,
  entries entries: List(#(String, Value)),
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  use _ <- result.try(case index.resolve(idx, segments) {
    Hit(_, types.IndexTable(..)) | Hit(_, types.IndexArrayOfTablesEntry(..)) ->
      Ok(Nil)
    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "concrete table",
        got: utils.index_entry_to_string(entry),
      ))
    Miss(..) | Fresh(_) -> Error(error.not_found(p))
  })
  use merged <- result.try(
    list.try_fold(entries, doc, fn(d, entry) {
      merge_one_entry(doc: d, base: segments, entry:, on_conflict:)
    }),
  )
  // Validate-after: the base was valid, so any new validation error is a dotted
  // key here redefining an existing concrete table/value (illegal TOML). This
  // offloads TOML's dotted-vs-header redefinition rules to the validator.
  case validate.count(merged.tree) {
    0 -> Ok(merged)
    _ ->
      Error(error.InvalidOperation(
        "merge_values",
        Some(
          "an entry would redefine an existing table or value at \""
          <> p
          <> "\"",
        ),
      ))
  }
}

fn merge_one_entry(
  doc doc: Document,
  base base: Path,
  entry entry: #(String, Value),
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  let #(rel_key, v) = entry
  use rel_segments <- result.try(path.parse(rel_key))
  use <- bool.guard(
    path.contains_index(rel_segments),
    return: Error(error.InvalidPath(
      "merge_values entry key must not contain index segments: " <> rel_key,
    )),
  )
  use idx <- index.with_index(doc)
  let full = list.append(base, rel_segments)
  case index.resolve(idx, full) {
    Hit(_, existing) ->
      case on_conflict {
        ops.OnConflictError ->
          Error(error.AlreadyExists(
            path: path.to_string(full),
            current: existing,
          ))
        ops.OnConflictSkip -> Ok(doc)
        ops.OnConflictOverwrite -> overwrite_leaf(doc:, path: full, value: v)
      }
    Miss(..) | Fresh(_) -> {
      let kv =
        builder.build_kv_from_path(
          key: path.path_to_table_header(rel_segments),
          value: value.to_cst(v),
        )
      cst.insert_kv(node: doc.tree, into: base, kv:, at: cst.KvAtEnd)
      |> result.map(primitives.rebuild(doc:, tree: _))
    }
  }
}

fn overwrite_leaf(
  doc doc: Document,
  path full: Path,
  value v: Value,
) -> Result(Document, MoltError) {
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: full)
    |> result.replace_error(error.not_found_path(full)),
  )
  let new_node =
    primitives.rebuild_kv_value(kv: cursor.focus, new_value: value.to_cst(v))
  zipper.set_focus(zipper: cursor, node: new_node)
  |> zipper.unzip
  |> primitives.rebuild(doc:, tree: _)
  |> Ok
}

// ---------------------------------------------------------------------------
// Structural promotion primitives
// ---------------------------------------------------------------------------

fn promote_implicit_to_concrete(
  doc doc: Document,
  path segments: Path,
) -> Result(Document, MoltError) {
  use idx <- index.with_index(doc)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexImplicitTable(..)) ->
      do_promote_implicit(doc:, idx:, segments:)
    Hit(_, types.IndexTable(..)) -> Ok(doc)
    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(path.to_string(segments)),
        expected: "implicit table",
        got: utils.index_entry_to_string(entry),
      ))
    Miss(..) | Fresh(_) -> Error(error.not_found_path(segments))
  }
}

fn do_promote_implicit(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  segments segments: Path,
) -> Result(Document, MoltError) {
  let to_rehome =
    collect_value_descendants_outside(idx, segments)
    |> order_by_source(idx:, doc:)

  use staged <- result.try(
    list.try_map(to_rehome, fn(full_path) {
      use old_kv <- result.try(cst.get(node: doc.tree, path: full_path))
      let new_key_segments = list.drop(full_path, list.length(segments))
      let new_key_names =
        list.filter_map(new_key_segments, fn(seg) {
          case seg {
            KeySegment(name) -> Ok(utils.quote_key(name))
            IndexSegment(_) -> Error(Nil)
          }
        })
      let new_kv =
        elements.rewrite_kv_key_in_place(kv: old_kv, new_key: new_key_names)
      Ok(#(full_path, new_kv))
    }),
  )

  use deleted_tree <- result.try(
    list.try_fold(staged, doc.tree, fn(tree, item) {
      let #(full_path, _) = item
      cst.delete(node: tree, path: full_path)
    }),
  )

  let key_only = path.path_to_table_header(segments)
  let header = builder.build_empty_table(key_only)
  use with_header <- result.try(cst.insert_table_node(
    node: deleted_tree,
    table: header,
  ))

  let section_cst_path = list.map(key_only, KeySegment)
  use new_tree <- result.try(
    list.try_fold(staged, with_header, fn(tree, item) {
      let #(_, new_kv) = item
      cst.insert_kv(
        node: tree,
        into: section_cst_path,
        kv: new_kv,
        at: cst.KvAtEnd,
      )
    }),
  )

  Ok(primitives.rebuild(doc:, tree: new_tree))
}

/// Re-order rehome `paths` into source order. `collect_value_descendants_outside`
/// folds the index dict, whose iteration order is backend-defined (Erlang sorts
/// terms; JS hashes), so the raw list scrambles the document's key order. Every
/// such dotted key is a sibling in one scope node — the implicit table's nearest
/// concrete ancestor, or root — because TOML forbids reopening a scope. That
/// node's children are already in document order, so we read them off directly.
/// Any path not found among the siblings (should not happen for valid TOML) is
/// appended rather than dropped, so no descendant is ever silently lost.
fn order_by_source(
  paths paths: List(Path),
  idx idx: types.DocumentIndex,
  doc doc: Document,
) -> List(Path) {
  let scope = rehome_scope(idx, paths)
  let ordered = case cst.get(node: doc.tree, path: scope) {
    Ok(scope_node) ->
      elements.child_key_paths(scope_node)
      |> list.map(fn(segs) { list.append(scope, list.map(segs, KeySegment)) })
      |> list.filter(list.contains(paths, _))
    _ -> []
  }
  let leftover = list.filter(paths, fn(p) { !list.contains(ordered, p) })
  list.append(ordered, leftover)
}

/// The scope node that holds the implicit table's outside dotted keys: the
/// `container` recorded on any one of them (uniform, by the single-scope rule).
fn rehome_scope(idx: types.DocumentIndex, paths: List(Path)) -> Path {
  case paths {
    [] -> []
    [first, ..] ->
      case index.get_path(index: idx, path: first) {
        Ok(types.IndexScalarValue(container:))
        | Ok(types.IndexArrayValue(container:))
        | Ok(types.IndexInlineTableValue(container:)) -> container
        _ -> []
      }
  }
}

fn collect_value_descendants_outside(
  idx: types.DocumentIndex,
  prefix: Path,
) -> List(Path) {
  let prefix_len = list.length(prefix)
  dict.fold(idx, [], fn(acc, key, entry) {
    let full_path = index.key_to_path(key)
    case path_starts_with(full_path, prefix) {
      False -> acc
      True ->
        case entry {
          types.IndexScalarValue(container:)
          | types.IndexArrayValue(container:)
          | types.IndexInlineTableValue(container:) ->
            case list.length(container) < prefix_len {
              True -> [full_path, ..acc]
              False -> acc
            }
          _ -> acc
        }
    }
  })
}

fn path_starts_with(full: Path, prefix: Path) -> Bool {
  case prefix, full {
    [], _ -> True
    [_, ..], [] -> False
    [p, ..ps], [f, ..fs] if p == f -> path_starts_with(fs, ps)
    _, _ -> False
  }
}
