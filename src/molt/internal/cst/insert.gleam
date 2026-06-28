//// The CST insertion/placement engine: places key/value nodes and table /
//// array-of-tables headers into a container at a resolved position, keeping
//// header ordering and blank-line separators consistent. The public `cst`
//// functions (`insert_kv`, `insert_array_of_tables_entry`, `ensure`,
//// `insert_table_node`) resolve a position and hand off to `place` / the
//// `ensure_*` helpers here.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import greenwood.{type Element, type Node, Node, NodeElement as N}
import greenwood/zipper
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/utils
import molt/types.{type PathSegment, type TomlKind}

/// Placement union passed to the core `place`. The `container` argument to
/// `place` is `[]` (root) for `FamilyScopeEnd`/`BeforeFamilyIndex`, or the
/// target table path for `KvRegionEnd`/`BeforeKvKey`.
pub type Placement {
  KvRegionEnd
  BeforeKvKey(key: String)
  FamilyScopeEnd(family: List(String))
  BeforeFamilyIndex(family: List(String), index: Int)
}

/// Place `new` into the container at `into` (root when empty), at `at`. The
/// container must be a Root / Table / array-of-tables node.
pub fn place(
  node node: Node(TomlKind),
  into container: List(PathSegment),
  new new: Node(TomlKind),
  at at: Placement,
) -> Result(Node(TomlKind), MoltError) {
  case container {
    [] -> Ok(do_insert_kv_in_placement(container: node, new:, at:))
    _ -> {
      use cursor <- result.try(query.get_cursor(node:, path: container))
      case cursor.focus.kind {
        types.Root | types.Table | types.ArrayOfTables ->
          zipper.map_focus(zipper: cursor, with: do_insert_kv_in_placement(
            container: _,
            new:,
            at:,
          ))
          |> zipper.unzip
          |> Ok
        _ ->
          Error(error.TypeMismatch(
            path: None,
            expected: "table-node",
            got: utils.toml_kind(cursor.focus.kind),
          ))
      }
    }
  }
}

/// Ensure a `[table]` header for `path` exists, inserting it in header order.
pub fn ensure_table(
  node node: Node(TomlKind),
  path path: List(String),
) -> Node(TomlKind) {
  let new_table = builder.build_empty_table(path)
  // Insert before any child tables (tables whose path starts with ours)
  table_ordered(node:, new_table:, path:)
}

/// Ensure an `[[array.of.tables]]` header for `path` exists, in header order.
pub fn ensure_array_of_tables(
  node node: Node(TomlKind),
  path path: List(String),
) -> Node(TomlKind) {
  let new_table = builder.build_empty_array_of_tables(path)
  // Insert before any child tables
  table_ordered(node:, new_table:, path:)
}

// Dispatch a Placement to the right placement helper.
fn do_insert_kv_in_placement(
  container container: Node(TomlKind),
  new new: Node(TomlKind),
  at at: Placement,
) -> Node(TomlKind) {
  case at {
    KvRegionEnd -> {
      let children =
        insert_after_last_kv(children: container.children, kv: new, acc: [])
      Node(..container, children:)
    }
    BeforeKvKey(key) -> {
      let children =
        do_insert_before_key(
          children: container.children,
          before: key,
          kv: new,
          acc: [],
        )
      Node(..container, children:)
    }
    FamilyScopeEnd(family) -> {
      let new_children =
        insert_after_path_scope(
          children: container.children,
          new_header: new,
          prefix: family,
        )
      Node(..container, children: new_children)
    }
    BeforeFamilyIndex(family:, index:) -> {
      let children =
        do_insert_before_index(
          children: container.children,
          path: family,
          index:,
          entry: new,
          current: 0,
          acc: [],
        )
      Node(..container, children:)
    }
  }
}

fn do_insert_before_key(
  children children: List(Element(TomlKind)),
  before before: String,
  kv kv: Node(TomlKind),
  acc acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> list.reverse([N(kv), ..acc])
    [N(n) as el, ..rest] if n.kind == types.KeyValue ->
      case elements.key_name(n.children) == Some(before) {
        True -> list.append(list.reverse(acc), [N(kv), el, ..rest])
        False ->
          do_insert_before_key(children: rest, before:, kv:, acc: [el, ..acc])
      }
    [el, ..rest] ->
      do_insert_before_key(children: rest, before:, kv:, acc: [el, ..acc])
  }
}

fn do_insert_before_index(
  children children: List(Element(TomlKind)),
  path segments: List(String),
  index index: Int,
  entry entry: Node(TomlKind),
  current current: Int,
  acc acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> list.reverse([N(entry), ..acc])
    [N(n) as el, ..rest] if n.kind == types.ArrayOfTables ->
      case elements.extract_key_segments(n.children) == segments {
        True if current == index ->
          list.append(list.reverse(acc), [N(entry), el, ..rest])
        True ->
          do_insert_before_index(
            children: rest,
            path: segments,
            index:,
            entry:,
            current: current + 1,
            acc: [el, ..acc],
          )
        False ->
          do_insert_before_index(
            children: rest,
            path: segments,
            index:,
            entry:,
            current:,
            acc: [el, ..acc],
          )
      }
    [el, ..rest] ->
      do_insert_before_index(
        children: rest,
        path: segments,
        index:,
        entry:,
        current:,
        acc: [el, ..acc],
      )
  }
}

fn insert_after_last_kv(
  children children: List(Element(TomlKind)),
  kv kv: Node(TomlKind),
  acc acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    // No more children: append at end
    [] -> list.reverse([N(kv), ..acc])
    // Hit a table: insert before it
    [N(n) as el, ..rest]
      if n.kind == types.Table || n.kind == types.ArrayOfTables
    -> list.append(list.reverse([N(kv), ..acc]), [el, ..rest])
    // Keep going past KVs and trivia
    [el, ..rest] -> insert_after_last_kv(children: rest, kv:, acc: [el, ..acc])
  }
}

/// Insert a table node before the first child table whose path is a descendant
/// of the new table's path. If no such child exists, append it at the end.
pub fn table_ordered(
  node node: Node(TomlKind),
  new_table new_table: Node(TomlKind),
  path segments: List(String),
) -> Node(TomlKind) {
  // The scope the new table belongs to: `["dependencies"]` for
  // `["dependencies", "squall"]`, empty for a top-level table.
  let parent_path = list.take(segments, list.length(segments) - 1)

  // `insert_table_ordered` owns the blank-line separator before a header,
  // independent of whatever leading trivia the built node arrived with (internal
  // builders prepend one; the public `build_table` returns a bare node): drop it
  // when the header lands first in the document (no spurious blank first line),
  // and ensure exactly one when content precedes it. User-authored leading
  // blanks live on pre-existing nodes and are never touched.
  let append = fn(into: Node(TomlKind)) {
    let table = case into.children {
      [] -> builder.drop_leading_newlines(new_table)
      _ -> builder.ensure_leading_newline(new_table)
    }
    greenwood.append_child(in: into, child: N(table))
  }

  case zipper.down_where(zipper.zip(node), is_descendant_table(_, segments)) {
    // A sub-table of the new table already exists; its header must come after
    // the new one, so insert immediately before it.
    Some(cursor) -> {
      // If that descendant is itself the first node, the inserted header takes
      // first position and must shed its separator.
      let table = case zipper.left(cursor) {
        None -> builder.drop_leading_newlines(new_table)
        Some(_) -> builder.ensure_leading_newline(new_table)
      }
      zipper.insert_left(cursor, N(table))
      |> option.map(zipper.unzip)
      |> option.unwrap(node)
    }
    None ->
      case parent_path {
        // Nested table with no existing descendants: group it with its parent
        // scope by inserting right after the last table already in that scope
        // (the parent header or one of its sub-tables), rather than at the end.
        [_, ..] ->
          case
            zipper.down_last_where(zipper.zip(node), in_parent_family(
              _,
              parent_path,
            ))
          {
            Some(cursor) ->
              zipper.insert_right(
                cursor,
                N(builder.ensure_leading_newline(new_table)),
              )
              |> option.map(zipper.unzip)
              |> option.unwrap(node)
            None -> append(node)
          }
        // Top-level table: append at the end.
        [] -> append(node)
      }
  }
}

// Inserts new_header after the last node whose path starts with `prefix`, or
// appends at end if none found.
fn insert_after_path_scope(
  children children: List(Element(TomlKind)),
  new_header new_header: Node(TomlKind),
  prefix prefix: List(String),
) -> List(Element(TomlKind)) {
  do_insert_after_path_scope(
    children:,
    new_header:,
    prefix:,
    saw_in_scope: False,
    acc: [],
  )
}

fn do_insert_after_path_scope(
  children children: List(Element(TomlKind)),
  new_header new_header: Node(TomlKind),
  prefix prefix: List(String),
  saw_in_scope saw_in_scope: Bool,
  acc acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> list.reverse([N(new_header), ..acc])
    [N(n) as el, ..rest]
      if n.kind == types.Table || n.kind == types.ArrayOfTables
    -> {
      let header_path = elements.extract_key_segments(n.children)
      case list.take(header_path, list.length(prefix)) == prefix {
        True ->
          do_insert_after_path_scope(
            children: rest,
            new_header:,
            prefix:,
            saw_in_scope: True,
            acc: [el, ..acc],
          )
        False ->
          case saw_in_scope {
            True ->
              list.reverse([N(new_header), ..acc])
              |> list.append([el, ..rest])
            False ->
              do_insert_after_path_scope(
                children: rest,
                new_header:,
                prefix:,
                saw_in_scope: False,
                acc: [el, ..acc],
              )
          }
      }
    }
    [el, ..rest] ->
      do_insert_after_path_scope(
        children: rest,
        new_header:,
        prefix:,
        saw_in_scope:,
        acc: [el, ..acc],
      )
  }
}

fn table_path(node: Node(TomlKind)) -> Result(List(String), Nil) {
  case node.kind {
    types.Table | types.ArrayOfTables ->
      Ok(elements.extract_key_segments(node.children))
    _ -> Error(Nil)
  }
}

fn is_descendant_table(node: Node(TomlKind), parent: List(String)) -> Bool {
  case table_path(node) {
    Ok(p) -> is_child_path(parent:, child: p)
    _ -> False
  }
}

fn in_parent_family(node: Node(TomlKind), parent: List(String)) -> Bool {
  case table_path(node) {
    Ok(p) -> p == parent || is_child_path(parent:, child: p)
    _ -> False
  }
}

/// Check if `child` path is a descendant of `parent` path.
fn is_child_path(
  parent parent: List(String),
  child child: List(String),
) -> Bool {
  case parent, child {
    [], [_, ..] -> True
    [p, ..prest], [c, ..crest] if p == c ->
      is_child_path(parent: prest, child: crest)
    _, _ -> False
  }
}
