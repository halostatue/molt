//// Builder functions for the CST functions.

import gleam/list
import greenwood.{
  type Element, type Node, Bare, Node, NodeElement as N, Token,
  TokenElement as T, Trivia,
}
import molt/internal/utils
import molt/types.{type TomlKind}

/// Drop synthetic leading newline(s) from a freshly built header that will sit
/// first in the document. Only safe on builder-made headers, whose leading
/// trivia is exactly the separator we added.
pub fn drop_leading_newlines(node: Node(TomlKind)) -> Node(TomlKind) {
  case node.trivia {
    Bare -> node
    Trivia(leading:, trailing:) ->
      Node(
        ..node,
        trivia: Trivia(
          leading: list.drop_while(leading, fn(t) { t.kind == types.Newline }),
          trailing:,
        ),
      )
  }
}

/// Ensure a header that follows existing content carries exactly one leading
/// newline separator, whatever trivia it arrived with: bare nodes (public
/// `build_table`) get one prepended; internal nodes already have one.
pub fn ensure_leading_newline(node: Node(TomlKind)) -> Node(TomlKind) {
  let newline = Token(kind: types.Newline, text: "")
  case node.trivia {
    Bare -> Node(..node, trivia: Trivia(leading: [newline], trailing: []))
    Trivia(leading: [first, ..], ..) if first.kind == types.Newline -> node
    Trivia(leading:, trailing:) ->
      Node(..node, trivia: Trivia(leading: [newline, ..leading], trailing:))
  }
}

pub fn build_empty_table(path: List(String)) -> Node(TomlKind) {
  greenwood.node_with_trivia(
    types.Table,
    children: list.append(wrap_brackets(build_key_tokens(path)), [
      T(Token(kind: types.Newline, text: "")),
    ]),
    trivia: Trivia(
      leading: [Token(kind: types.Newline, text: "")],
      trailing: [],
    ),
  )
}

pub fn build_empty_array_of_tables(path: List(String)) -> Node(TomlKind) {
  greenwood.node_with_trivia(
    types.ArrayOfTables,
    children: list.append(wrap_double_brackets(build_key_tokens(path)), [
      T(Token(kind: types.Newline, text: "")),
    ]),
    trivia: Trivia(
      leading: [Token(kind: types.Newline, text: "")],
      trailing: [],
    ),
  )
}

pub fn rewrite_header_path(
  table table: Node(TomlKind),
  new_path new_path: List(String),
) -> Node(TomlKind) {
  Node(..table, children: rebuild_header(table.children, new_path))
}

pub fn build_kv_node(
  key key: String,
  value value: Element(TomlKind),
) -> Node(TomlKind) {
  let children = [
    T(utils.make_key_token(key)),
    T(Token(kind: types.Whitespace, text: " ")),
    T(Token(kind: types.Equals, text: "")),
    T(Token(kind: types.Whitespace, text: " ")),
    value,
    T(Token(kind: types.Newline, text: "")),
  ]
  greenwood.node(types.KeyValue, children)
}

/// Build a KV node from a list of key segments (supports dotted keys).
pub fn build_kv_from_path(
  key key: List(String),
  value value: Element(TomlKind),
) -> Node(TomlKind) {
  let key_elements = case key {
    [single] -> [T(utils.make_key_token(single))]
    _ -> [
      N(greenwood.node(types.Key, build_key_tokens(key))),
    ]
  }
  let children =
    list.flatten([
      key_elements,
      [
        T(Token(kind: types.Whitespace, text: " ")),
        T(Token(kind: types.Equals, text: "")),
        T(Token(kind: types.Whitespace, text: " ")),
        value,
        T(Token(kind: types.Newline, text: "")),
      ],
    ])
  greenwood.node(types.KeyValue, children)
}

pub fn build_inline_kv(
  key key: String,
  value value: Element(TomlKind),
) -> Node(TomlKind) {
  let children = [
    T(utils.make_key_token(key)),
    T(Token(kind: types.Whitespace, text: " ")),
    T(Token(kind: types.Equals, text: "")),
    T(Token(kind: types.Whitespace, text: " ")),
    value,
  ]
  greenwood.node(types.KeyValue, children)
}

pub fn build_key_tokens(path: List(String)) -> List(Element(TomlKind)) {
  case path {
    [] -> []
    [first, ..rest] -> {
      let first_tok = T(utils.make_key_token(first))
      list.fold(rest, [first_tok], fn(acc, segment) {
        list.append(acc, [
          T(Token(kind: types.Dot, text: "")),
          T(utils.make_key_token(segment)),
        ])
      })
    }
  }
}

fn wrap_brackets(keys: List(Element(TomlKind))) -> List(Element(TomlKind)) {
  let open = T(Token(kind: types.LeftBracket, text: ""))
  let close = T(Token(kind: types.RightBracket, text: ""))
  [open, ..list.append(keys, [close])]
}

fn wrap_double_brackets(
  keys: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  let ob = T(Token(kind: types.LeftBracket, text: ""))
  let cb = T(Token(kind: types.RightBracket, text: ""))
  [ob, ob, ..list.append(keys, [cb, cb])]
}

fn rebuild_header(
  children: List(Element(TomlKind)),
  new_path: List(String),
) -> List(Element(TomlKind)) {
  let #(brackets, rest) =
    list.split_while(children, fn(el) {
      case el {
        T(Token(kind: types.LeftBracket, ..)) -> True
        _ -> False
      }
    })
  let #(_old_keys, rest) =
    list.split_while(rest, fn(el) {
      case el {
        T(Token(kind: types.RightBracket, ..)) -> False
        _ -> True
      }
    })

  list.flatten([brackets, build_key_tokens(new_path), rest])
}
