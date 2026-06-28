//// molt/internal/document: TOML document operation document.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import greenwood.{type Node, type Zipper}
import greenwood/zipper
import molt/cst
import molt/error.{type MoltError}
import molt/internal/cst/elements
import molt/internal/document/arrays
import molt/internal/document/comments
import molt/internal/document/index
import molt/internal/document/remove
import molt/internal/document/representation
import molt/internal/document/reshape
import molt/internal/document/structure
import molt/internal/document/values
import molt/internal/path
import molt/ops
import molt/types.{
  type Document, type Path, type TomlKind, IndexSegment, KeySegment,
}
import molt/value.{type Value}

pub fn run(
  doc doc: Document,
  op op: ops.Operation,
) -> Result(Document, MoltError) {
  case op {
    ops.Set(path: "", ..) -> Error(error.InvalidOperation("set", None))
    ops.Set(path: p, value:) -> values.set(doc:, path: p, value:)

    ops.Remove(path: "") -> Error(error.InvalidOperation("remove", None))
    ops.Remove(path: p) -> remove.delete(doc:, path: p)

    ops.Move(from: "", ..) | ops.Move(to: "", ..) ->
      Error(error.InvalidOperation("move", None))
    ops.Move(from:, to:) -> reshape.move(doc:, from:, to:)

    ops.Rename(path: "", ..) -> Error(error.InvalidOperation("rename", None))
    ops.Rename(path: p, to:) -> reshape.rename(doc:, path: p, to:)

    ops.EnsureExists(path: "", ..) ->
      Error(error.InvalidOperation("ensure_exists", None))
    ops.EnsureExists(path: p, kind:) ->
      structure.ensure_exists(doc:, path: p, kind:)

    ops.MergeValues(path: "", ..) ->
      Error(error.InvalidOperation("merge_values", None))
    ops.MergeValues(path: p, entries:, on_conflict:) ->
      structure.merge_values(doc:, path: p, entries:, on_conflict:)

    ops.MoveKeys(from:, to:, keys:, on_conflict:) ->
      reshape.move_keys(doc:, from:, to:, keys:, on_conflict:)

    ops.Transfer(from:, to:, on_conflict:) ->
      reshape.merge(doc:, from:, into: to, on_conflict:)

    ops.Append(path: "", ..) -> Error(error.InvalidOperation("append", None))
    ops.Append(path: p, value:) -> arrays.append(doc:, path: p, value:)

    ops.Concat(path: "", ..) -> Error(error.InvalidOperation("concat", None))
    ops.Concat(path: p, values:) -> arrays.concat(doc:, path: p, values:)

    ops.Insert(path: "", ..) -> Error(error.InvalidOperation("insert", None))
    ops.Insert(path: p, before:, value:) ->
      arrays.insert(doc:, path: p, before:, value:)

    ops.InsertKey(path: p, before:, key:, value:) ->
      values.insert_key(doc:, path: p, before:, key:, value:)

    ops.Update(path: "", ..) -> Error(error.InvalidOperation("update", None))
    ops.Update(path: p, with:) -> values.update(doc:, path: p, with:)

    ops.Representation(path: "", ..) ->
      Error(error.InvalidOperation("representation", None))
    ops.Representation(path: p, form:) ->
      representation.set_representation(doc:, path: p, form:)

    ops.MoveComments(from:, to:) -> comments.move_comments(doc:, from:, to:)

    // Document-level (head/tail) comments are addressed by slot via
    // `set_document_comments`, not by path; `comments.set_comments` rejects the
    // empty path.
    ops.SetComments(path: p, comments:) ->
      comments.set_comments(doc:, path: p, comments:)

    ops.Place(path: "", ..) -> Error(error.InvalidOperation("place", None))
    ops.Place(path: p, value:) -> values.replace(doc:, path: p, value:)
  }
}

pub fn list_keys(
  doc doc: Document,
  at path: Path,
) -> Result(List(String), MoltError) {
  use index <- result.try(index.get_index(doc))
  case path {
    [] -> Ok(index.root_children(index))
    _ ->
      case index.get_path(index:, path:) {
        Ok(types.IndexTable(children:))
        | Ok(types.IndexImplicitTable(children:))
        | Ok(types.IndexArrayOfTablesEntry(children:, ..)) -> Ok(children)
        Ok(types.IndexArrayOfTables(..)) ->
          Error(error.TypeMismatch(
            path: Some(path.to_string(path)),
            expected: "a table entry (use an index to select an entry)",
            got: "array of tables",
          ))
        Ok(_) ->
          Error(error.TypeMismatch(
            path: Some(path.to_string(path)),
            expected: "a table",
            got: "a value",
          ))
        Error(Nil) -> Error(error.not_found_path(path))
      }
  }
}

pub fn get_value(
  doc doc: Document,
  at path: Path,
  key key: String,
) -> Result(Value, MoltError) {
  use kv_node <- result.try(require_key(doc:, at: path, key:))

  Ok(value.from_cst(kv_node))
}

/// Get a value by its container path and full dotted key path within that
/// container. The kv_key is the key segments relative to the container.
pub fn get_value_at(
  doc doc: Document,
  container container: Path,
  kv_key kv_key: Path,
) -> Result(Value, MoltError) {
  let full_path = list.append(container, kv_key)
  use container_node <- result.try(find_container(doc:, at: container))
  use kv_node <- result.try(
    cst.get(node: container_node, path: kv_key)
    |> result.replace_error(error.not_found_path(full_path)),
  )
  Ok(value.from_cst(kv_node))
}

/// Find the container node at a path that may include IndexSegments.
/// Returns the table/entry node that contains the children at that path.
fn find_container(
  doc doc: Document,
  at segments: Path,
) -> Result(Node(TomlKind), MoltError) {
  use <- bool.guard(segments == [], return: Ok(doc.tree))

  use <- bool.lazy_guard(has_index_segment(segments), return: fn() {
    find_container_indexed(doc.tree, segments)
    |> result.replace_error(error.not_found_path(segments))
  })

  cst.get(node: doc.tree, path: segments)
  |> result.replace_error(error.not_found_path(segments))
}

/// Walk flat root siblings using the greenwood zipper to find the container
/// for an indexed path. All [[AoT]] headers are flat siblings under root, so
/// we navigate with down_where (first descent) and right_where/right_n_where
/// for subsequent entries.
fn find_container_indexed(
  tree: Node(TomlKind),
  path: Path,
) -> Result(Node(TomlKind), Nil) {
  navigate_flat(
    cursor: zipper.zip(tree),
    path:,
    prefix: [],
    first: True,
    boundary: None,
  )
  |> option.map(fn(c) { c.focus })
  |> option.to_result(Nil)
}

/// Navigate the flat root sibling structure to find the container for an
/// indexed path. All [[AoT]] headers are flat siblings under root.
///
/// `boundary` is the path of the enclosing AoT entry's header: any right
/// sibling with that path marks the end of the current entry's scope. It is
/// None at the root level (no enclosing AoT) and Some(parent_prefix) after
/// descending into an AoT entry.
fn navigate_flat(
  cursor cursor: Zipper(TomlKind),
  path path: Path,
  prefix prefix: List(String),
  first first: Bool,
  boundary boundary: Option(List(String)),
) -> Option(Zipper(TomlKind)) {
  let stop = case boundary {
    None -> fn(_: Node(TomlKind)) { False }
    Some(b) -> is_array_of_tables_with_prefix(_, b)
  }
  case path {
    [] ->
      zipper.right_until(
        cursor,
        fn(node) {
          { node.kind == types.Table || node.kind == types.ArrayOfTables }
          && elements.extract_key_segments(node.children) == prefix
        },
        stop,
      )

    [KeySegment(k), ..rest] ->
      navigate_flat(
        cursor:,
        path: rest,
        prefix: list.append(prefix, [k]),
        first:,
        boundary:,
      )

    [IndexSegment(n), ..rest] -> {
      let pred = is_array_of_tables_with_prefix(_, prefix)
      let cursor = case first {
        True ->
          zipper.down_where(cursor, pred)
          |> option.then(zipper.right_n_until(_, n, pred, stop))
        False ->
          zipper.right_until(cursor, pred, stop)
          |> option.then(zipper.right_n_until(_, n, pred, stop))
      }
      use cursor <- option.then(cursor)
      case rest {
        [] -> Some(cursor)
        _ ->
          navigate_flat(
            cursor:,
            path: rest,
            prefix:,
            first: False,
            boundary: Some(prefix),
          )
      }
    }
  }
}

fn is_array_of_tables_with_prefix(
  node: Node(TomlKind),
  prefix: List(String),
) -> Bool {
  node.kind == types.ArrayOfTables
  && elements.extract_key_segments(node.children) == prefix
}

/// Find a container and look up a key in it, returning the KV node.
fn require_key(
  doc doc: Document,
  at segments: Path,
  key key: String,
) -> Result(Node(TomlKind), MoltError) {
  use table_node <- result.try(find_container(doc:, at: segments))
  cst.get(node: table_node, path: [KeySegment(key)])
  |> result.replace_error(
    list.append(segments, [KeySegment(key)])
    |> error.not_found_path(),
  )
}

fn has_index_segment(path: Path) -> Bool {
  list.any(path, fn(s) {
    case s {
      IndexSegment(_) -> True
      _ -> False
    }
  })
}
