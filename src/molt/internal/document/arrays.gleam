import gleam/bool
import gleam/list
import gleam/option.{Some}
import gleam/result
import greenwood.{type Node, Node, NodeElement as N}
import molt/cst
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/document/index.{Fresh, Hit, Miss}
import molt/internal/document/primitives
import molt/internal/path
import molt/internal/utils
import molt/types.{type Document, type Path, type TomlKind}
import molt/value.{type Value}

type ArrayPosition {
  AtEnd
  Before(Int)
}

pub fn append(
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
  case index.resolve(idx, segments) {
    Hit(_, types.IndexArrayOfTables(..)) ->
      do_modify_aot(doc:, path: segments, position: AtEnd, value: val)

    Hit(_, types.IndexArrayValue(..)) ->
      do_modify_inline_array(
        doc:,
        idx:,
        path: segments,
        position: AtEnd,
        new_value: val,
      )

    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "array or array of tables",
        got: utils.index_entry_to_string(entry),
      ))

    Miss(_, ancestor, _) ->
      case ancestor {
        types.IndexArrayValue(..) ->
          do_modify_inline_array(
            doc:,
            idx:,
            path: segments,
            position: AtEnd,
            new_value: val,
          )
        _ ->
          Error(error.TypeMismatch(
            path: Some(p),
            expected: "array",
            got: utils.index_entry_to_string(ancestor),
          ))
      }

    Fresh(_) -> Error(error.not_found(p))
  }
}

/// Append several values in order. The bulk form of `append`: resolution and
/// per-value validation are identical, so an array of tables path requires
/// every value to be table-like and an array path accepts any value. On the
/// first rejected value the operation short-circuits and the caller's document
/// is left untouched. An empty list is a no-op that does not resolve `path`.
///
/// For an array of tables this resolves once, builds every entry node, inserts
/// them in a single pass over the CST, and rebuilds the document index _once_:
/// rather than folding `append`, which would rebuild the whole index per entry
/// (index builds are expensive). The array-value path keeps folding `append`:
/// that path updates the index incrementally per item, so there is no per-item
/// rebuild to avoid.
pub fn concat(
  doc doc: Document,
  path p: String,
  values vals: List(Value),
) -> Result(Document, MoltError) {
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  // Resolve regardless of list length: an empty `vals` is a no-op on a valid
  // array/AoT target, but a missing or non-array target errors the same way a
  // single `append` would. (Only value-validity is worth checking before
  // resolution; `append` does that per item on the fold branch.)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexArrayOfTables(..)) ->
      concat_aot(doc:, path: segments, values: vals)

    // Array value (or an array-element ancestor) reuses append's single-item
    // logic, which mutates the index in place so the fold incurs no rebuilds.
    // An empty `vals` folds to a no-op, the target having already been validated.
    Hit(_, types.IndexArrayValue(..)) | Miss(_, types.IndexArrayValue(..), _) ->
      list.try_fold(vals, doc, fn(d, val) {
        append(doc: d, path: p, value: val)
      })

    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "array or array of tables",
        got: utils.index_entry_to_string(entry),
      ))

    Miss(_, ancestor, _) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "array",
        got: utils.index_entry_to_string(ancestor),
      ))

    Fresh(_) -> Error(error.not_found(p))
  }
}

/// Append many entries to an array of tables with a single index rebuild.
/// Validates and builds all entry nodes up front (so a non-table value aborts
/// before any mutation), threads the CST through one insert per entry, then
/// rebuilds the index once.
fn concat_aot(
  doc doc: Document,
  path segments: Path,
  values vals: List(Value),
) -> Result(Document, MoltError) {
  use entry_nodes <- result.try(
    list.try_map(vals, fn(val) {
      use entries <- result.try(table_entries_or_mismatch(segments, val))
      Ok(build_aot_entry_node(segments, entries))
    }),
  )
  use new_tree <- result.try(
    list.try_fold(entry_nodes, doc.tree, fn(tree, entry_node) {
      cst.insert_array_of_tables_entry(
        node: tree,
        into: segments,
        entry: entry_node,
        at: cst.EntryAtEnd,
      )
    }),
  )
  Ok(primitives.rebuild(doc:, tree: new_tree))
}

pub fn insert(
  doc doc: Document,
  path p: String,
  before before: Int,
  value val: Value,
) -> Result(Document, MoltError) {
  use <- bool.guard(
    value.type_of(val) == "invalid",
    return: Error(error.InvalidTomlValue(path: p, text: value.invalid_text(val))),
  )
  use segments <- result.try(path.parse(p))
  use idx <- index.with_index(doc)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexArrayValue(..)) ->
      do_modify_inline_array(
        doc:,
        idx:,
        path: segments,
        position: Before(before),
        new_value: val,
      )

    Hit(_, types.IndexArrayOfTables(count:, ..)) -> {
      use i <- result.try(
        utils.resolve_insert_position(before, count)
        |> result.replace_error(insert_bounds_error(
          segments:,
          before:,
          len: count,
        )),
      )
      let position = case i == count {
        True -> AtEnd
        False -> Before(i)
      }
      do_modify_aot(doc:, path: segments, position:, value: val)
    }

    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "array or array of tables",
        got: utils.index_entry_to_string(entry),
      ))

    Miss(_, ancestor, _) ->
      case ancestor {
        types.IndexArrayValue(..) ->
          do_modify_inline_array(
            doc:,
            idx:,
            path: segments,
            position: Before(before),
            new_value: val,
          )
        _ ->
          Error(error.TypeMismatch(
            path: Some(p),
            expected: "array",
            got: utils.index_entry_to_string(ancestor),
          ))
      }

    Fresh(_) -> Error(error.not_found(p))
  }
}

// ---------------------------------------------------------------------------
// AoT helpers
// ---------------------------------------------------------------------------

fn do_modify_aot(
  doc doc: Document,
  path segments: Path,
  position position: ArrayPosition,
  value val: Value,
) -> Result(Document, MoltError) {
  use entries <- result.try(table_entries_or_mismatch(segments, val))
  let entry_node = build_aot_entry_node(segments, entries)
  case position {
    AtEnd ->
      cst.insert_array_of_tables_entry(
        node: doc.tree,
        into: segments,
        entry: entry_node,
        at: cst.EntryAtEnd,
      )
      |> result.map(fn(tree) { primitives.rebuild(doc:, tree:) })
    Before(i) ->
      cst.insert_array_of_tables_entry(
        node: doc.tree,
        into: segments,
        entry: entry_node,
        at: cst.BeforeIndex(i),
      )
      |> result.map(fn(tree) { primitives.rebuild(doc:, tree:) })
  }
}

fn table_entries_or_mismatch(
  segments: Path,
  val: Value,
) -> Result(List(#(String, Value)), MoltError) {
  value.table_to_list(val)
  |> result.replace_error(error.TypeMismatch(
    path: Some(path.to_string(segments)),
    expected: "table",
    got: value.type_of(val),
  ))
}

fn build_aot_entry_node(
  segments: Path,
  entries: List(#(String, Value)),
) -> Node(TomlKind) {
  let key_path = path.path_to_table_header(segments)
  let header = builder.build_empty_array_of_tables(key_path)
  let kv_children =
    list.map(entries, fn(entry) {
      let #(k, v) = entry
      // `build_kv_node` -> `make_key_token` already quotes non-bare keys; do
      // NOT `quote_key(k)` first or the key is double-quoted.
      N(builder.build_kv_node(key: k, value: value.to_cst(v)))
    })
  Node(..header, children: list.append(header.children, kv_children))
}

// ---------------------------------------------------------------------------
// Inline array helpers
// ---------------------------------------------------------------------------

fn do_modify_inline_array(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  path segments: Path,
  position position: ArrayPosition,
  new_value new_value: Value,
) -> Result(Document, MoltError) {
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: segments)
    |> result.replace_error(error.not_found_path(segments)),
  )
  use new_value_el <- result.try(
    case primitives.find_kv_value(cursor.focus, types.Array) {
      Ok(array_node) -> {
        let items = elements.extract_array_items(array_node)
        use i <- result.try(resolve_array_position(position:, items:, segments:))
        let layout = elements.array_layout(array_node)
        let new_item =
          elements.build_array_item(value: value.to_cst(new_value), layout:)
        let #(head, tail) = list.split(items, i)
        let new_array =
          elements.rebuild_array(
            source: array_node,
            items: list.flatten([head, [new_item], tail]),
          )
        Ok(N(new_array))
      }
      // The path resolved to an existing non-array element (a scalar or an
      // inline table). Appending/inserting there is a type error: never
      // silently wrap the element into a fresh array (that would destroy it).
      Error(Nil) -> {
        let got = case
          primitives.find_kv_value(cursor.focus, types.InlineTable)
        {
          Ok(_) -> "inline table"
          Error(Nil) -> "scalar value"
        }
        Error(error.TypeMismatch(
          path: Some(path.to_string(segments)),
          expected: "array",
          got:,
        ))
      }
    },
  )
  primitives.cursor_replace_value(
    doc:,
    idx:,
    path: segments,
    new_value: new_value_el,
  )
}

fn resolve_array_position(
  position position: ArrayPosition,
  items items: List(Node(TomlKind)),
  segments segments: Path,
) -> Result(Int, MoltError) {
  let len = list.length(items)
  case position {
    AtEnd -> Ok(len)
    Before(i) ->
      utils.resolve_insert_position(i, len)
      |> result.replace_error(insert_bounds_error(segments:, before: i, len:))
  }
}

fn insert_bounds_error(
  segments segments: Path,
  before before: Int,
  len len: Int,
) -> MoltError {
  error.IndexOutOfRange(
    path: path.to_string(segments),
    index: before,
    length: len,
  )
}
