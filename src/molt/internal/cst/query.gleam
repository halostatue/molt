import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import greenwood.{
  type Element, type Node, type Zipper, NodeElement as N, Token,
  TokenElement as T,
}
import greenwood/zipper
import molt/error.{type MoltError}
import molt/internal/cst/elements
import molt/internal/utils
import molt/types.{type PathSegment, type TomlKind, IndexSegment, KeySegment}

pub fn get(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
) -> Result(Node(TomlKind), MoltError) {
  get_cursor(node:, path: segments)
  |> result.map(fn(cursor) { cursor.focus })
}

pub fn get_cursor(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
) -> Result(Zipper(TomlKind), MoltError) {
  get_cursor_where(node:, path: segments, where: fn(_) { True })
}

pub fn get_cursor_where(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  where predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  node
  |> zipper.zip
  |> resolve_path(path: segments, visited: [], predicate:)
}

/// Collect consecutive KeySegments from the front of a path as strings.
pub fn collect_key_prefix(path: List(PathSegment)) -> List(String) {
  case path {
    [KeySegment(k), ..rest] -> [k, ..collect_key_prefix(rest)]
    _ -> []
  }
}

fn resolve_path(
  cursor cursor: Zipper(TomlKind),
  path segments: List(PathSegment),
  visited visited: List(PathSegment),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  case segments {
    [] -> Ok(cursor)

    [IndexSegment(index), ..rest] ->
      resolve_path_by_index(
        cursor:,
        index:,
        path: segments,
        rest:,
        visited:,
        predicate:,
      )

    [KeySegment(_), ..] ->
      resolve_path_by_key(cursor:, path: segments, visited:, predicate:)
  }
}

fn resolve_path_by_index(
  cursor cursor: Zipper(TomlKind),
  index index: Int,
  path segments: List(PathSegment),
  rest rest: List(PathSegment),
  visited visited: List(PathSegment),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  case cursor.focus.kind {
    // Focused on Array node: find nth ArrayElement
    types.Array -> {
      use cursor <- result.try(
        resolve_into_nth_array_element(cursor:, index:)
        |> result.replace_error(error.not_found_path3(segments, rest, visited)),
      )

      resolve_path(
        cursor:,
        path: rest,
        visited: [IndexSegment(index), ..visited],
        predicate:,
      )
    }

    // Focused on KV node: descend into value first, then index
    types.KeyValue -> {
      use cursor <- result.try(
        resolve_into_kv_value(cursor)
        |> result.replace_error(error.not_found_path3(segments, rest, visited)),
      )
      resolve_path(cursor:, path: segments, visited:, predicate:)
    }

    // Focused on ArrayElement: descend into its value
    types.ArrayElement -> {
      use cursor <- result.try(
        resolve_into_array_element_value(cursor)
        |> result.replace_error(error.not_found_path3(segments, rest, visited)),
      )
      resolve_path(cursor:, path: segments, visited:, predicate:)
    }

    _ -> Error(error.not_found_path2(segments, visited))
  }
}

fn resolve_path_by_key(
  cursor cursor: Zipper(TomlKind),
  path segments: List(PathSegment),
  visited visited: List(PathSegment),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  case cursor.focus.kind {
    // Focused on InlineTable: find KV by key within it
    types.InlineTable ->
      resolve_into_inline_table(cursor:, path: segments, visited:, predicate:)

    // Focused on KV node: descend into value first
    types.KeyValue -> {
      use cursor <- result.try(
        resolve_into_kv_value(cursor)
        |> result.replace_error(error.not_found_path2(segments, visited)),
      )
      resolve_path(cursor:, path: segments, visited:, predicate:)
    }

    // Focused on ArrayElement: descend into its value
    types.ArrayElement -> {
      use cursor <- result.try(
        resolve_into_array_element_value(cursor)
        |> result.replace_error(error.not_found_path2(segments, visited)),
      )
      resolve_path(cursor:, path: segments, visited:, predicate:)
    }

    _ -> resolve_into_key(cursor:, path: segments, visited:, predicate:)
  }
}

/// Descend into the value node within a KV node (the Array or InlineTable child).
fn resolve_into_kv_value(
  cursor: Zipper(TomlKind),
) -> Result(Zipper(TomlKind), Nil) {
  zipper.down_where(cursor, fn(n) {
    n.kind == types.Array || n.kind == types.InlineTable
  })
  |> option.to_result(Nil)
}

/// Descend into the value node within an ArrayElement (InlineTable, Array, or
/// skip to content).
fn resolve_into_array_element_value(
  cursor: Zipper(TomlKind),
) -> Result(Zipper(TomlKind), Nil) {
  zipper.down_where(cursor, fn(n) {
    n.kind == types.InlineTable || n.kind == types.Array
  })
  |> option.to_result(Nil)
}

/// Find the nth ArrayElement within an Array node.
fn resolve_into_nth_array_element(
  cursor cursor: Zipper(TomlKind),
  index index: Int,
) -> Result(Zipper(TomlKind), Nil) {
  case zipper.down_where(cursor, is_array_element) {
    None -> Error(Nil)
    Some(child_cursor) -> {
      let count =
        list.count(cursor.focus.children, is_node(_, is_array_element))
      let offset = utils.resolve_index(index, count)

      use <- bool.guard(offset < 0, return: Error(Nil))

      zipper.right_n_where(
        zipper: child_cursor,
        by: offset,
        predicate: is_array_element,
      )
      |> option.to_result(Nil)
    }
  }
}

/// Navigate within an InlineTable node to find a KV by key name.
fn resolve_into_inline_table(
  cursor cursor: Zipper(TomlKind),
  path segments: List(PathSegment),
  visited visited: List(PathSegment),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  case segments {
    [] -> Ok(cursor)
    [KeySegment(key), ..rest] -> {
      use cursor <- result.try(
        zipper.down_where(cursor, is_kv_named(_, key))
        |> option.to_result(error.not_found_path3(segments, rest, visited)),
      )

      case rest {
        [] -> {
          use <- bool.guard(predicate(cursor.focus), return: Ok(cursor))
          Error(error.not_found_path2(segments, visited))
        }
        _ -> {
          let visited = [KeySegment(key), ..visited]
          resolve_path(cursor: cursor, path: rest, visited:, predicate:)
        }
      }
    }
    _ -> Error(error.not_found_path2(segments, visited))
  }
}

fn resolve_into_key(
  cursor cursor: Zipper(TomlKind),
  path segments: List(PathSegment),
  visited visited: List(PathSegment),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  let prefix = collect_key_prefix(segments)
  let after = list.drop(segments, list.length(prefix))
  let new_visited =
    list.append(list.reverse(list.map(prefix, KeySegment)), visited)

  case after {
    [IndexSegment(index), ..rest] ->
      resolve_into_index_after_key(
        cursor:,
        index:,
        prefix:,
        path: segments,
        rest:,
        visited:,
        new_visited:,
        predicate:,
      )

    _ -> {
      // Terminal step: apply user predicate
      let filter = case after == [] {
        True -> predicate
        False -> fn(_) { True }
      }

      case resolve_over_key(cursor:, prefix:, filter:) {
        Ok(found) ->
          resolve_path(
            cursor: found,
            path: after,
            visited: new_visited,
            predicate:,
          )
        // Full prefix failed: try just first key as KV (value boundary)
        Error(resolved_prefix) ->
          resolve_under_key(
            cursor:,
            after:,
            prefix:,
            path: segments,
            visited:,
            resolved_prefix:,
            predicate:,
          )
      }
    }
  }
}

fn resolve_into_index_after_key(
  cursor cursor: Zipper(TomlKind),
  index index: Int,
  prefix prefix: List(String),
  path segments: List(PathSegment),
  rest rest: List(PathSegment),
  visited visited: List(PathSegment),
  new_visited new_visited: List(PathSegment),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  case resolve_into_array_of_tables(cursor:, prefix:, index:) {
    Ok(found) -> {
      let sub_prefix = collect_key_prefix(rest)
      let after = list.drop(rest, list.length(sub_prefix))
      resolve_path(cursor: found, path: rest, visited: new_visited, predicate:)
      |> result.lazy_or(fn() {
        resolve_aot_scoped_path(
          cursor: found,
          aot_prefix: prefix,
          sub_prefix:,
          full_sub_prefix: sub_prefix,
          after:,
          segments:,
          visited: new_visited,
          predicate:,
        )
      })
    }

    // Not an array of tables: try as KV with inline array value
    Error(Nil) ->
      case prefix {
        [key] ->
          case zipper.down_where(cursor, is_kv_named(_, key)) {
            Some(kv_cursor) ->
              resolve_path(
                cursor: kv_cursor,
                path: [IndexSegment(index), ..rest],
                visited: [KeySegment(key), ..visited],
                predicate:,
              )
            None -> Error(error.not_found_path2(segments, visited))
          }
        _ -> Error(error.not_found_path2(segments, visited))
      }
  }
}

fn resolve_over_key(
  cursor cursor: Zipper(TomlKind),
  prefix prefix: List(String),
  filter filter: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), List(String)) {
  case
    zipper.down_where(cursor, fn(n) { is_table_at(n, prefix) && filter(n) })
  {
    Some(cursor) -> Ok(cursor)
    None ->
      case prefix {
        [] -> Error([])
        [key] ->
          zipper.down_where(cursor, fn(n) { is_kv_named(n, key) && filter(n) })
          |> option.to_result([])
        _ ->
          // Try matching a KV with a dotted key path equal to the full prefix
          case
            zipper.down_where(cursor, fn(n) {
              is_kv_with_path(n, prefix) && filter(n)
            })
          {
            Some(cursor) -> Ok(cursor)
            None ->
              // Try progressively shorter prefixes as table paths. Pass the
              // full prefix so that once a table is found, the remainder
              // includes ALL trailing segments: not just the segment we
              // last looked at as a potential table.
              try_shorter_table_prefix(
                cursor:,
                prefix:,
                full_prefix: prefix,
                filter:,
              )
          }
      }
  }
}

fn resolve_under_key(
  cursor cursor: Zipper(TomlKind),
  after after: List(PathSegment),
  prefix prefix: List(String),
  path segments: List(PathSegment),
  visited visited: List(PathSegment),
  resolved_prefix resolved_prefix: List(String),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  case prefix {
    [first_key, ..rest_keys] -> {
      case zipper.down_where(cursor, is_kv_named(_, first_key)) {
        Some(kv_cursor) -> {
          let rest_path = list.append(list.map(rest_keys, KeySegment), after)
          let kv_visited = [KeySegment(first_key), ..visited]
          resolve_path(
            cursor: kv_cursor,
            path: rest_path,
            visited: kv_visited,
            predicate:,
          )
        }
        None -> {
          let visited =
            list.append(
              list.reverse(list.map(resolved_prefix, KeySegment)),
              visited,
            )
          Error(error.not_found_path2(segments, visited))
        }
      }
    }
    _ -> {
      let visited =
        list.append(
          list.reverse(list.map(resolved_prefix, KeySegment)),
          visited,
        )
      Error(error.not_found_path2(segments, visited))
    }
  }
}

fn try_shorter_table_prefix(
  cursor cursor: Zipper(TomlKind),
  prefix prefix: List(String),
  full_prefix full_prefix: List(String),
  filter filter: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), List(String)) {
  // `prefix` shrinks each recursion as we search for a matching shorter table
  // path. `full_prefix` stays constant so that when we find a table, the
  // remainder to resolve inside it covers ALL trailing segments: not just
  // the one we last looked at.
  case list.take(prefix, list.length(prefix) - 1) {
    [] -> Error([])
    init ->
      case zipper.down_where(cursor, is_table_at(_, init)) {
        Some(inner_cursor) -> {
          let rest = list.drop(full_prefix, list.length(init))
          case resolve_over_key(cursor: inner_cursor, prefix: rest, filter:) {
            Ok(cursor) -> Ok(cursor)
            Error(_) -> Error(init)
          }
        }
        None ->
          try_shorter_table_prefix(cursor:, prefix: init, full_prefix:, filter:)
      }
  }
}

fn resolve_into_array_of_tables(
  cursor cursor: Zipper(TomlKind),
  prefix prefix: List(String),
  index index: Int,
) -> Result(Zipper(TomlKind), Nil) {
  case zipper.down_where(cursor, is_array_of_tables_at(_, prefix)) {
    Some(cursor) -> resolve_to_nth_match(cursor:, index:, path: prefix)
    None ->
      case prefix {
        [key, ..rest] if rest != [] -> {
          use cursor <- result.try(
            zipper.down_where(cursor, is_table_at(_, [key]))
            |> option.to_result(Nil),
          )
          resolve_into_array_of_tables(cursor:, prefix: rest, index:)
        }
        _ -> Error(Nil)
      }
  }
}

fn is_kv_named(node: Node(TomlKind), key: String) -> Bool {
  node.kind == types.KeyValue && elements.key_name(node.children) == Some(key)
}

fn is_kv_with_path(node: Node(TomlKind), path: List(String)) -> Bool {
  node.kind == types.KeyValue && kv_key_segments(node.children) == path
}

/// Extract key segments from a KV node's children, stopping at Equals.
fn kv_key_segments(children: List(Element(TomlKind))) -> List(String) {
  case children {
    [] -> []
    [T(Token(kind: types.Equals, ..)), ..] -> []
    [N(n), ..] if n.kind == types.Key ->
      elements.extract_key_segments(n.children)
    [T(Token(kind: types.BareKey, text:)), ..rest] -> [
      text,
      ..kv_key_segments(rest)
    ]
    [T(Token(kind: types.BasicString, text:)), ..rest] -> [
      utils.unescape_basic_string(text),
      ..kv_key_segments(rest)
    ]
    [T(Token(kind: types.LiteralString, text:)), ..rest] -> [
      text,
      ..kv_key_segments(rest)
    ]
    [_, ..rest] -> kv_key_segments(rest)
  }
}

fn is_table_at(node: Node(TomlKind), path: List(String)) -> Bool {
  { node.kind == types.Table || node.kind == types.ArrayOfTables }
  && elements.extract_key_segments(node.children) == path
}

fn is_array_of_tables_at(node: Node(TomlKind), path: List(String)) -> Bool {
  node.kind == types.ArrayOfTables
  && elements.extract_key_segments(node.children) == path
}

fn resolve_to_nth_match(
  cursor cursor: Zipper(TomlKind),
  index index: Int,
  path segments: List(String),
) -> Result(Zipper(TomlKind), Nil) {
  // Count all matching siblings to support negative indexing
  let count = count_right_matches(cursor:, path: segments) + 1
  let resolved = utils.resolve_index(index:, length: count)

  case resolved {
    0 -> Ok(cursor)
    n if n > 0 ->
      zipper.right_n_where(
        zipper: cursor,
        by: n,
        predicate: is_array_of_tables_at(_, segments),
      )
      |> option.to_result(Nil)
    _ -> Error(Nil)
  }
}

// Within the scope of an AoT entry, sub-tables like `[items.nested]` are
// right siblings at root level rather than children of `[[items]]`. After
// navigating to an AoT entry via IndexSegment, this function scans right
// siblings for a section table whose full key path matches
// `aot_prefix ++ sub_prefix`, stopping at the next entry of the same AoT.
// It tries progressively shorter sub-prefixes so that `items[0].nested.k`
// finds `[items.nested]` first, then descends to find `k`.
fn resolve_aot_scoped_path(
  cursor cursor: Zipper(TomlKind),
  aot_prefix aot_prefix: List(String),
  sub_prefix sub_prefix: List(String),
  full_sub_prefix full_sub_prefix: List(String),
  after after: List(PathSegment),
  segments segments: List(PathSegment),
  visited visited: List(PathSegment),
  predicate predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  case sub_prefix {
    [] -> Error(error.not_found_path2(segments, visited))
    _ -> {
      let full_table_path = list.append(aot_prefix, sub_prefix)
      let remaining =
        list.append(
          list.map(
            list.drop(full_sub_prefix, list.length(sub_prefix)),
            KeySegment,
          ),
          after,
        )
      let filter = case remaining {
        [] -> predicate
        _ -> fn(_: Node(TomlKind)) { True }
      }
      let stop = is_array_of_tables_at(_, aot_prefix)
      case
        zipper.right_until(
          cursor,
          fn(n) { is_table_at(n, full_table_path) && filter(n) },
          stop,
        )
      {
        Some(sub_cursor) ->
          resolve_path(
            cursor: sub_cursor,
            path: remaining,
            visited:,
            predicate:,
          )
        None ->
          resolve_aot_scoped_path(
            cursor:,
            aot_prefix:,
            sub_prefix: list.take(sub_prefix, list.length(sub_prefix) - 1),
            full_sub_prefix:,
            after:,
            segments:,
            visited:,
            predicate:,
          )
      }
    }
  }
}

fn is_array_element(n: Node(TomlKind)) -> Bool {
  n.kind == types.ArrayElement
}

fn is_node(
  el: Element(TomlKind),
  predicate: fn(Node(TomlKind)) -> Bool,
) -> Bool {
  case el {
    N(n) -> predicate(n)
    _ -> False
  }
}

fn count_right_matches(
  cursor cursor: Zipper(TomlKind),
  path segments: List(String),
) -> Int {
  case zipper.right_where(cursor, is_array_of_tables_at(_, segments)) {
    Some(cursor) -> 1 + count_right_matches(cursor:, path: segments)
    None -> 0
  }
}
