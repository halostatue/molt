import gleam/list
import gleam/option.{None, Some}
import gleam/result
import greenwood.{
  type Element, type Node, type Zipper, Node, NodeElement as N, Token,
  TokenElement as T,
}
import greenwood/zipper
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/document/index.{
  ConcreteAppend, InlineDescend, RootDottedKey,
}
import molt/internal/path
import molt/internal/utils
import molt/types.{
  type Document, type Path, type TomlKind, Document, IndexSegment, KeySegment,
}
import molt/value.{type Value}

pub fn patch(
  doc doc: Document,
  tree tree: Node(TomlKind),
  idx idx: types.DocumentIndex,
) -> Document {
  Document(..doc, tree:, index: Some(idx))
}

/// Replace the existing value token at path via zipper.
pub fn cursor_replace_value(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  path segments: Path,
  new_value new_value: Element(TomlKind),
) -> Result(Document, MoltError) {
  let key = index.path_to_index_key(segments)
  let #(container, _) = path.split_last_segment(segments)
  let entry = index.entry_for_element(new_value, container:)
  let idx = index.update_entry(idx:, key:, entry:)
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: segments)
    |> result.replace_error(error.not_found_path(segments)),
  )
  let new_node = case cursor.focus.kind {
    types.ArrayElement ->
      rebuild_array_element(element: cursor.focus, new_value:)
    _ -> rebuild_kv_value(kv: cursor.focus, new_value:)
  }
  zipper.set_focus(zipper: cursor, node: new_node)
  |> zipper.unzip
  |> patch(doc:, idx:)
  |> Ok
}

pub fn rebuild_array_element(
  element element: Node(TomlKind),
  new_value new_value: Element(TomlKind),
) -> Node(TomlKind) {
  case element.children {
    [_, ..trailing] -> Node(..element, children: [new_value, ..trailing])
    [] -> Node(..element, children: [new_value])
  }
}

pub fn rebuild_kv_value(
  kv kv: Node(TomlKind),
  new_value new_value: Element(TomlKind),
) -> Node(TomlKind) {
  case elements.split_at_equals(kv.children) {
    #(prefix, [eq, ..after_eq]) -> {
      let #(ws, after_ws) = elements.split_leading_ws(after_eq)
      let #(old_value, trailing) = elements.split_before_trivia(after_ws)
      let trailing_ws = elements.take_trailing_ws(old_value)
      Node(
        ..kv,
        children: list.flatten([
          prefix,
          [eq],
          ws,
          [new_value],
          trailing_ws,
          trailing,
        ]),
      )
    }
    // No Equals token: degenerate KV, leave unchanged.
    #(_, []) -> kv
  }
}

/// Update the index for a new node, then write it to the CST.
pub fn write_at_site(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  site site: index.InsertionSite,
  full_path full_path: Path,
  val val: Value,
) -> Result(Document, MoltError) {
  let idx_key = index.path_to_index_key(full_path)
  // The container is the concrete scope that owns this KV in the CST: NOT the
  // logical parent path.
  let container = case site {
    RootDottedKey(_) -> []
    ConcreteAppend(container_path) -> container_path
    InlineDescend(_) -> path.split_last_segment(full_path).0
  }
  let entry = index.entry_for_value(val, container:)
  let idx = index.ensure_implicit_tables(idx:, path: full_path)
  let idx = index.insert_entry(idx:, key: idx_key, entry:)
  do_write_new(doc:, idx:, full_path:, val:, site:)
}

/// Insert a KV node before the first Table or ArrayOfTables child at root.
/// This satisfies TOML's ordering requirement: root dotted keys must precede
/// the table headers that close their scope. If no header is present, the KV
/// is appended at the end.
pub fn insert_kv_before_first_header(
  tree tree: Node(TomlKind),
  kv kv: Node(TomlKind),
) -> Node(TomlKind) {
  let kv_el = N(kv)
  let #(before, after) =
    list.split_while(tree.children, fn(el) {
      case el {
        N(n) -> n.kind != types.Table && n.kind != types.ArrayOfTables
        _ -> True
      }
    })
  // When `after == []` (no header found), this appends; otherwise the kv
  // lands between `before` and the first header in `after`.
  Node(..tree, children: list.flatten([before, [kv_el], after]))
}

/// Mutate the CST to place a new KV at the given insertion site.
/// The index has already been updated by the caller.
fn do_write_new(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  full_path full_path: Path,
  val val: Value,
  site site: index.InsertionSite,
) -> Result(Document, MoltError) {
  case site {
    ConcreteAppend(container_path) ->
      write_new_concrete_append(doc:, idx:, full_path:, val:, container_path:)

    RootDottedKey(full_path) ->
      write_new_root_dotted_key(doc:, idx:, full_path:, val:)

    InlineDescend(full_path) ->
      write_new_inline_descend(doc:, idx:, full_path:, val:)
  }
}

fn write_new_concrete_append(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  full_path full_path: Path,
  val val: Value,
  container_path container_path: Path,
) -> Result(Document, MoltError) {
  let tail = list.drop(full_path, list.length(container_path))
  let key_names =
    list.filter_map(tail, fn(seg) {
      case seg {
        KeySegment(name) -> Ok(utils.quote_key(name))
        IndexSegment(_) -> Error(Nil)
      }
    })
  let kv = builder.build_kv_from_path(key: key_names, value: value.to_cst(val))
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: container_path)
    |> result.replace_error(error.not_found_path(container_path)),
  )
  zipper.map_focus(zipper: cursor, with: greenwood.append_child(
    in: _,
    child: N(kv),
  ))
  |> zipper.unzip
  |> patch(doc:, idx:)
  |> Ok
}

/// Mutate the CST to place a new KV at the given insertion site.
/// The index has already been updated by the caller.
fn write_new_root_dotted_key(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  full_path full_path: Path,
  val val: Value,
) -> Result(Document, MoltError) {
  let key_names =
    list.filter_map(full_path, fn(seg) {
      case seg {
        KeySegment(name) -> Ok(utils.quote_key(name))
        IndexSegment(_) -> Error(Nil)
      }
    })
  let kv = builder.build_kv_from_path(key: key_names, value: value.to_cst(val))
  let new_tree = insert_kv_before_first_header(tree: doc.tree, kv:)
  Ok(patch(doc:, tree: new_tree, idx:))
}

fn write_new_inline_descend(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  full_path full_path: Path,
  val val: Value,
) -> Result(Document, MoltError) {
  case query.get_cursor(node: doc.tree, path: full_path) {
    Ok(cursor) -> {
      let new_node = case cursor.focus.kind {
        types.ArrayElement ->
          rebuild_array_element(
            element: cursor.focus,
            new_value: value.to_cst(val),
          )
        _ -> rebuild_kv_value(kv: cursor.focus, new_value: value.to_cst(val))
      }
      zipper.set_focus(zipper: cursor, node: new_node)
      |> zipper.unzip
      |> patch(doc:, idx:)
      |> Ok
    }

    _ -> write_new_inline_descend_missing(doc:, idx:, full_path:, val:)
  }
}

fn write_new_inline_descend_missing(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  full_path full_path: Path,
  val val: Value,
) -> Result(Document, MoltError) {
  // Path doesn't exist yet inside the inline value: insert new KV
  let #(container_path, last) = path.split_last_segment(full_path)
  case last {
    KeySegment(key) -> {
      use parent_cursor <- result.try(
        query.get_cursor(node: doc.tree, path: container_path)
        |> result.replace_error(error.not_found_path(full_path)),
      )

      let kv_el =
        N(builder.build_inline_kv(
          key: utils.quote_key(key),
          value: value.to_cst(val),
        ))
      // parent_cursor focuses on a KV (`x = { ... }`): descend into the
      // InlineTable value before inserting. If it's already on an InlineTable,
      // use it directly.
      use insert_cursor <- result.try(focus_inline_container(parent_cursor))
      let new_inline =
        insert_kv_into_inline_container(insert_cursor.focus, kv_el)
      zipper.set_focus(zipper: insert_cursor, node: new_inline)
      |> zipper.unzip
      |> patch(doc:, idx:)
      |> Ok
    }
    _ -> Error(error.not_found_path(full_path))
  }
}

/// Focus the InlineTable inside a KV cursor; or return cursor unchanged if
/// it already focuses an InlineTable.
fn focus_inline_container(
  cursor: Zipper(TomlKind),
) -> Result(Zipper(TomlKind), MoltError) {
  case cursor.focus.kind {
    types.InlineTable -> Ok(cursor)
    types.KeyValue ->
      zipper.down_where(cursor, fn(n) { n.kind == types.InlineTable })
      |> option.to_result(error.TypeMismatch(
        path: None,
        expected: "inline table",
        got: utils.toml_kind(cursor.focus.kind),
      ))
    other ->
      Error(error.TypeMismatch(
        path: None,
        expected: "inline table",
        got: utils.toml_kind(other),
      ))
  }
}

fn insert_kv_into_inline_container(
  container: Node(TomlKind),
  kv_el: Element(TomlKind),
) -> Node(TomlKind) {
  let children = list.reverse(container.children)
  let new_children = case children {
    [T(Token(kind: types.RightBrace, ..)) as rb, ..rest] ->
      list.reverse([
        rb,
        kv_el,
        T(Token(kind: types.Whitespace, text: " ")),
        T(Token(kind: types.Comma, text: "")),
        ..rest
      ])
    _ -> list.append(container.children, [kv_el])
  }
  Node(..container, children: new_children)
}

/// Rebuild a document with a new tree, recomputing the index from scratch.
/// Use when structural changes (inserts, deletes, promotions) make the old
/// index stale. For in-place value swaps, prefer `patch/3` with a
/// pre-updated index entry instead.
pub fn rebuild(doc doc: Document, tree tree: Node(TomlKind)) -> Document {
  Document(..doc, tree:, index: index.build_tree_index(tree) |> Some)
}

/// Return the first child Node(TomlKind) of `kv` whose kind matches `kind`.
/// Used to extract the InlineTable or Array sitting in value position.
pub fn find_kv_value(
  kv kv: Node(TomlKind),
  kind kind: TomlKind,
) -> Result(Node(TomlKind), Nil) {
  list.find_map(kv.children, fn(el) {
    case el {
      N(n) if n.kind == kind -> Ok(n)
      _ -> Error(Nil)
    }
  })
}
