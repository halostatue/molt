//// Shared utilities for working with flat `List(Element(TomlKind))` children.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import greenwood.{
  type Element, type Node, type Token, Bare, Node, NodeElement as N, Token,
  TokenElement as T, Trivia,
}
import molt/internal/cst/builder
import molt/internal/utils
import molt/types.{type TomlKind}

/// The document's prevailing newline style, used to render synthesized newlines
/// (which carry empty text — see `emitter.resolve_newlines`). TOML permits only
/// Unix (`"\n"`) or Windows (`"\r\n"`) line endings, so this returns `"\r\n"`
/// exactly when the first newline that carries real text is CRLF, and `"\n"`
/// otherwise — never a bare `"\r"`, which would be invalid TOML.
///
/// Only newlines with non-empty text count: synthesized (empty-text) newlines —
/// e.g. the lines of a head comment added to a document that had none — sit at
/// the top but say nothing about the document's style, so they are skipped.
pub fn document_newline(node: Node(TomlKind)) -> String {
  case first_literal_newline(node) {
    Some("\r\n") -> "\r\n"
    _ -> "\n"
  }
}

fn first_literal_newline(node: Node(TomlKind)) -> Option(String) {
  case node.trivia {
    Trivia(leading:, trailing:) ->
      first_literal_newline_in_tokens(leading)
      |> option.lazy_or(fn() {
        first_literal_newline_in_children(node.children)
      })
      |> option.lazy_or(fn() { first_literal_newline_in_tokens(trailing) })
    Bare -> first_literal_newline_in_children(node.children)
  }
}

fn first_literal_newline_in_tokens(
  tokens: List(Token(TomlKind)),
) -> Option(String) {
  case tokens {
    [] -> None
    [Token(kind: types.Newline, text:), ..] if text != "" -> Some(text)
    [_, ..rest] -> first_literal_newline_in_tokens(rest)
  }
}

fn first_literal_newline_in_children(
  els: List(Element(TomlKind)),
) -> Option(String) {
  case els {
    [] -> None
    [T(Token(kind: types.Newline, text:)), ..] if text != "" -> Some(text)
    [T(_), ..rest] -> first_literal_newline_in_children(rest)
    [N(n), ..rest] ->
      first_literal_newline(n)
      |> option.lazy_or(fn() { first_literal_newline_in_children(rest) })
  }
}

pub fn key_path(children: List(Element(TomlKind))) -> Option(List(String)) {
  case children {
    [] -> None
    [T(Token(kind: types.Equals, ..)), ..] -> None
    [N(n), ..] if n.kind == types.Key -> Some(extract_key_segments(n.children))
    [T(Token(kind: types.BareKey, text:)), ..] -> Some([text])
    [T(Token(kind: types.Integer, text:)), ..] -> Some([text])
    [T(Token(kind: types.BasicString, text:)), ..] ->
      Some([utils.unescape_basic_string(text)])
    [T(Token(kind: types.LiteralString, text:)), ..] -> Some([text])
    [_, ..rest] -> key_path(rest)
  }
}

/// Full dotted key paths of the immediate key-value children of `node`, in
/// source order. Recovers document order where the index alone (a dict) cannot.
pub fn child_key_paths(node: Node(TomlKind)) -> List(List(String)) {
  list.filter_map(node.children, fn(el) {
    case el {
      N(kv) if kv.kind == types.KeyValue ->
        option.to_result(key_path(kv.children), Nil)
      _ -> Error(Nil)
    }
  })
}

/// Skip leading trivia (whitespace, newlines) from an element list.
pub fn skip_trivia(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest] -> skip_trivia(rest)
    _ -> children
  }
}

/// Skip trivia including comments.
pub fn skip_all_trivia(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest]
    | [T(Token(kind: types.Comment, ..)), ..rest] -> skip_all_trivia(rest)
    _ -> children
  }
}

/// Extract key segment strings from a list of children (key tokens only).
/// Handles BareKey, Integer, BasicString, LiteralString separated by Dot.
pub fn extract_key_segments(children: List(Element(TomlKind))) -> List(String) {
  list.filter_map(children, fn(el) {
    case el {
      T(Token(kind: types.BareKey, text:)) -> Ok(text)
      T(Token(kind: types.Integer, text:)) -> Ok(text)
      T(Token(kind: types.BasicString, text:)) ->
        Ok(utils.unescape_basic_string(text))
      T(Token(kind: types.LiteralString, text:)) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

/// Get the first key name from a children list (stops at Equals).
pub fn key_name(children: List(Element(TomlKind))) -> Option(String) {
  case children {
    [] -> None
    [T(Token(kind: types.Equals, ..)), ..] -> None
    [T(Token(kind: types.BareKey, text:)), ..] -> Some(text)
    [T(Token(kind: types.Integer, text:)), ..] -> Some(text)
    [T(Token(kind: types.BasicString, text:)), ..] ->
      Some(utils.unescape_basic_string(text))
    [T(Token(kind: types.LiteralString, text:)), ..] -> Some(text)
    [_, ..rest] -> key_name(rest)
  }
}

/// Get value tokens (everything after the first Equals token).
pub fn value_tokens(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> []
    [T(Token(kind: types.Equals, ..)), ..rest] -> rest
    [_, ..rest] -> value_tokens(rest)
  }
}

/// Find the first meaningful (non-trivia) element.
pub fn find_first_value(
  elements: List(Element(TomlKind)),
) -> Option(Element(TomlKind)) {
  case elements {
    [] -> None
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest]
    | [T(Token(kind: types.Comment, ..)), ..rest] -> find_first_value(rest)
    [el, ..] -> Some(el)
  }
}

/// Get all KeyValue child nodes from an element list.
pub fn get_kv_children(
  children: List(Element(TomlKind)),
) -> List(Node(TomlKind)) {
  child_nodes_of_kind(children:, kind: types.KeyValue)
}

/// Returns True if the children list contains at least one valid TOML
/// structural node (table, array of tables, or key-value with equals) or
/// contains only trivia tokens (BOM, comments, whitespace, newlines): no
/// structural TOML content.
pub fn is_toml(children: List(Element(TomlKind))) -> Bool {
  has_toml_nodes(children) || is_only_trivia(children)
}

/// Split children at the first Equals token. Returns `(before, [equals, ..after])`.
/// If no Equals is present, the second list is empty.
pub fn split_at_equals(
  children: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  list.split_while(children, fn(el) {
    case el {
      T(Token(kind: types.Equals, ..)) -> False
      _ -> True
    }
  })
}

/// Split off leading whitespace tokens. Returns `(whitespace, rest)`.
pub fn split_leading_ws(
  children: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  list.split_while(children, fn(el) {
    case el {
      T(Token(kind: types.Whitespace, ..)) -> True
      _ -> False
    }
  })
}

/// Split children before the first trailing-trivia token (Comment or Newline).
/// Returns `(content_with_inline_ws, trivia_tail)`.
pub fn split_before_trivia(
  children: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  list.split_while(children, fn(el) {
    case el {
      T(Token(kind: types.Comment, ..)) -> False
      T(Token(kind: types.Newline, ..)) -> False
      _ -> True
    }
  })
}

/// Return the suffix of `els` that is purely whitespace tokens (in original
/// order). Used to preserve any pre-comment / pre-newline padding on a value.
pub fn take_trailing_ws(
  els: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  els
  |> list.reverse
  |> list.take_while(fn(el) {
    case el {
      T(Token(kind: types.Whitespace, ..)) -> True
      _ -> False
    }
  })
  |> list.reverse
}

// ---------------------------------------------------------------------------
// Inline value extraction and rebuilding
//
// Primitives that preserve formatting, comments, and trivia when restructuring
// inline tables and arrays. Parser-derived InlineTable / Array nodes store
// per-element formatting (commas, surrounding whitespace, trailing newline) in
// each KV / ArrayElement's own children + leading trivia, so extraction and
// rebuild can stay structural: the items themselves carry their formatting.
// ---------------------------------------------------------------------------

/// Extract the list of KV nodes from an InlineTable node. Each KV carries its
/// own leading trivia (comments / newlines before the KV) and same-line
/// trailing tokens (comma, whitespace, comment, newline) in its children.
pub fn extract_inline_entries(
  inline_table: Node(TomlKind),
) -> List(Node(TomlKind)) {
  get_kv_children(inline_table.children)
}

/// Extract the list of ArrayElement nodes from an Array node. Each
/// ArrayElement carries its leading trivia and trailing same-line tokens.
pub fn extract_array_items(array: Node(TomlKind)) -> List(Node(TomlKind)) {
  child_nodes_of_kind(children: array.children, kind: types.ArrayElement)
}

/// How an array lays its elements out, so inserted elements match the existing
/// shape: `[1, 2]` (single line, `, ` between elements) vs a multi-line array
/// where each element sits on its own indented line ending in `,`. The line-ness
/// is inferred from the source's existing trivia, so no new `TomlKind` is
/// needed (cf. the Nl multiline-string variants).
pub type ArrayLayout {
  SingleLine
  MultiLine(indent: String)
}

/// Infer an array's layout from its existing elements: multi-line if any element
/// carries a `Newline` (in its children or trivia), with the indent copied from
/// the first element that has leading whitespace (default two spaces).
pub fn array_layout(array: Node(TomlKind)) -> ArrayLayout {
  let items = extract_array_items(array)
  case list.any(items, element_is_multiline) {
    False -> SingleLine
    True -> MultiLine(detect_array_indent(items))
  }
}

fn element_is_multiline(element: Node(TomlKind)) -> Bool {
  let in_children =
    list.any(element.children, fn(el) {
      case el {
        T(Token(kind: types.Newline, ..)) -> True
        _ -> False
      }
    })
  in_children
  || case element.trivia {
    Trivia(leading:, trailing:) ->
      list.any(list.append(leading, trailing), fn(t) { t.kind == types.Newline })
    Bare -> False
  }
}

fn detect_array_indent(items: List(Node(TomlKind))) -> String {
  case list.filter_map(items, leading_indent) {
    [indent, ..] -> indent
    [] -> "  "
  }
}

fn leading_indent(element: Node(TomlKind)) -> Result(String, Nil) {
  case element.trivia {
    Trivia(leading:, ..) ->
      list.find_map(leading, fn(t) {
        case t.kind {
          types.Whitespace -> Ok(t.text)
          _ -> Error(Nil)
        }
      })
    Bare -> Error(Nil)
  }
}

/// Build a new ArrayElement wrapping a value element, shaped to the target
/// array's layout. A single-line item is bare (`rebuild_array` adds the `, `
/// separator); a multi-line item carries its own `,` + newline and an indent
/// matching its siblings, so it lands on its own line.
pub fn build_array_item(
  value value: Element(TomlKind),
  layout layout: ArrayLayout,
) -> Node(TomlKind) {
  case layout {
    SingleLine ->
      Node(kind: types.ArrayElement, children: [value], trivia: Bare)
    MultiLine(indent:) ->
      Node(
        kind: types.ArrayElement,
        children: [
          value,
          T(Token(kind: types.Comma, text: "")),
          T(Token(kind: types.Newline, text: "")),
        ],
        trivia: Trivia(
          leading: [Token(kind: types.Whitespace, text: indent)],
          trailing: [],
        ),
      )
  }
}

/// Rebuild an Array node from the given items. Reuses the source array's
/// LeftBracket and RightBracket (with any trailing bare trivia between the
/// last element and the closing bracket) so trailing comments survive. Inserts
/// layout-appropriate separators where missing on non-last items.
pub fn rebuild_array(
  source source: Node(TomlKind),
  items items: List(Node(TomlKind)),
) -> Node(TomlKind) {
  let normalized = ensure_separating_commas(items, array_layout(source))
  let #(prefix, body) = take_up_to_token(source.children, types.LeftBracket)
  let trailing = extract_trailing_after_last(body, types.ArrayElement)
  let item_elements = list.map(normalized, fn(item) { N(item) })
  Node(..source, children: list.flatten([prefix, item_elements, trailing]))
}

/// Convert an inline-style KV (no trailing newline, may have trailing comma)
/// to a section-style KV (trailing newline, no comma). Preserves the value
/// and any same-line trailing comment.
pub fn kv_to_section_form(kv: Node(TomlKind)) -> Node(TomlKind) {
  let children =
    kv.children
    |> list.filter(fn(el) {
      case el {
        T(Token(kind: types.Comma, ..)) -> False
        _ -> True
      }
    })
    |> trim_edge_whitespace
    |> ensure_trailing_newline
  strip_leading_trivia_whitespace(Node(..kv, children:))
}

/// Drop leading `Whitespace` tokens from a node's leading trivia. The first
/// entry of an inline table carries the `{ ` padding as leading trivia, which
/// would otherwise indent the section-form line; leading comments (and the
/// newlines around them) are preserved.
fn strip_leading_trivia_whitespace(node: Node(TomlKind)) -> Node(TomlKind) {
  case node.trivia {
    Bare -> node
    Trivia(leading:, trailing:) ->
      Node(..node, trivia: Trivia(leading: drop_ws_tokens(leading), trailing:))
  }
}

fn drop_ws_tokens(tokens: List(Token(TomlKind))) -> List(Token(TomlKind)) {
  case tokens {
    [Token(kind: types.Whitespace, ..), ..rest] -> drop_ws_tokens(rest)
    _ -> tokens
  }
}

/// Drop leading and trailing `Whitespace` tokens — the inline-table padding
/// (`{ `, ` ,`, ` }`) that would otherwise leak onto a section-form line as
/// stray indentation or trailing spaces. Interior spacing (`key = value`) is
/// untouched, since it sits between non-whitespace tokens.
fn trim_edge_whitespace(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  children
  |> drop_leading_whitespace
  |> list.reverse
  |> drop_leading_whitespace
  |> list.reverse
}

fn drop_leading_whitespace(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [T(Token(kind: types.Whitespace, ..)), ..rest] ->
      drop_leading_whitespace(rest)
    _ -> children
  }
}

fn ensure_trailing_newline(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case list.reverse(children) {
    [T(Token(kind: types.Newline, ..)), ..] -> children
    _ -> list.append(children, [T(Token(kind: types.Newline, text: ""))])
  }
}

/// Assemble an `InlineTable` node from section-style KV nodes (each ending in a
/// newline, possibly carrying comments). Comment-free input collapses to a
/// single line `{ a = 1, b = 2 }`; comment-bearing input becomes a multiline
/// inline table that preserves the comment text: valid and lossless under
/// TOML 1.1. Empty input is `{}`.
pub fn section_kvs_to_inline_table(
  kvs: List(Node(TomlKind)),
) -> Node(TomlKind) {
  let body = case kvs {
    [] -> []
    _ ->
      case list.any(kvs, kv_has_comment) {
        False -> single_line_inline_body(kvs)
        True -> multiline_inline_body(kvs)
      }
  }
  Node(
    kind: types.InlineTable,
    children: list.flatten([
      [T(Token(kind: types.LeftBrace, text: ""))],
      body,
      [T(Token(kind: types.RightBrace, text: ""))],
    ]),
    trivia: Bare,
  )
}

/// Assemble an `Array` node holding the given inline-table nodes as elements:
/// `[{ … }, { … }]`. The separating comma (and a space) live INSIDE each
/// non-last `ArrayElement`: the structure the parser produces: so the tree
/// validates, not just the emitted string.
pub fn inline_tables_to_array(tables: List(Node(TomlKind))) -> Node(TomlKind) {
  let last = list.length(tables) - 1
  let items =
    list.index_map(tables, fn(t, i) {
      N(with_trailing_separator(
        build_array_item(value: N(t), layout: SingleLine),
        i < last,
      ))
    })
  Node(
    kind: types.Array,
    children: list.flatten([
      [T(Token(kind: types.LeftBracket, text: ""))],
      items,
      [T(Token(kind: types.RightBracket, text: ""))],
    ]),
    trivia: Bare,
  )
}

/// Build a multiline inline array of the given inline tables, baking each
/// table's leading / trailing comments onto its own element line:
///
///     [
///       # leading
///       { … }, # trailing
///       { … }
///     ]
///
/// Multiline arrays are valid TOML (1.0+), so this is how a converted array of
/// tables keeps every per-entry comment — a single-line array has nowhere to
/// put them, and a trailing comment placed inline would swallow the `]`.
/// `comments` is one `#(leading, trailing)` pair per table, in order.
pub fn inline_tables_to_multiline_array(
  tables tables: List(Node(TomlKind)),
  comments comments: List(#(List(String), Option(String))),
) -> Node(TomlKind) {
  let last = list.length(tables) - 1
  let items =
    list.index_map(list.zip(tables, comments), fn(pair, i) {
      let #(table, #(leading, trailing)) = pair
      N(multiline_array_element(
        table:,
        leading:,
        trailing:,
        needs_comma: i < last,
      ))
    })
  Node(
    kind: types.Array,
    children: list.flatten([
      [T(Token(kind: types.LeftBracket, text: "["))],
      items,
      [
        T(Token(kind: types.Newline, text: "")),
        T(Token(kind: types.RightBracket, text: "]")),
      ],
    ]),
    trivia: Bare,
  )
}

/// One element of a multiline inline array: a `\n  ` (plus any leading comment
/// lines) in leading trivia, then the inline table, then a comma (unless last)
/// and any trailing comment held inline.
fn multiline_array_element(
  table table: Node(TomlKind),
  leading leading: List(String),
  trailing trailing: Option(String),
  needs_comma needs_comma: Bool,
) -> Node(TomlKind) {
  let newline = Token(kind: types.Newline, text: "")
  let indent = Token(kind: types.Whitespace, text: "  ")
  let leading_trivia =
    list.flatten([
      [newline, indent],
      list.flat_map(leading, fn(c) {
        [Token(kind: types.Comment, text: c), newline, indent]
      }),
    ])
  let comma = case needs_comma {
    True -> [T(Token(kind: types.Comma, text: ","))]
    False -> []
  }
  let trailing_tokens = case trailing {
    Some(c) -> [
      T(Token(kind: types.Whitespace, text: " ")),
      T(Token(kind: types.Comment, text: c)),
    ]
    None -> []
  }
  Node(
    kind: types.ArrayElement,
    children: list.flatten([[N(table)], comma, trailing_tokens]),
    trivia: Trivia(leading: leading_trivia, trailing: []),
  )
}

fn single_line_inline_body(
  kvs: List(Node(TomlKind)),
) -> List(Element(TomlKind)) {
  let space = T(Token(kind: types.Whitespace, text: " "))
  let last = list.length(kvs) - 1
  let entries =
    list.index_map(kvs, fn(kv, i) {
      N(with_trailing_separator(strip_kv_to_inline(kv), i < last))
    })
  list.flatten([[space], entries, [space]])
}

/// Append a trailing `, ` to a KV / ArrayElement node when it is not the last
/// entry, keeping the separator inside the node (parser-canonical).
fn with_trailing_separator(
  node: Node(TomlKind),
  needs_comma: Bool,
) -> Node(TomlKind) {
  use <- bool.guard(!needs_comma, node)
  Node(
    ..node,
    children: list.append(node.children, [
      T(Token(kind: types.Comma, text: "")),
      T(Token(kind: types.Whitespace, text: " ")),
    ]),
  )
}

fn multiline_inline_body(kvs: List(Node(TomlKind))) -> List(Element(TomlKind)) {
  list.index_map(kvs, fn(kv, i) {
    let children =
      kv.children
      |> ensure_trailing_newline
      |> insert_comma_before_trailing
    // The first entry carries the newline after `{`; later entries get theirs
    // from the previous entry's trailing newline. The entry's trailing comment
    // stays on `trivia.trailing` (like every line-terminated node).
    let leading = case i {
      0 -> [Token(kind: types.Newline, text: "")]
      _ -> []
    }
    N(
      Node(
        ..kv,
        children:,
        trivia: Trivia(leading:, trailing: greenwood.trailing_trivia(from: kv)),
      ),
    )
  })
}

/// Strip a section KV to inline form: drop the trailing newline, leaving
/// `key = value`. Only used on comment-free KVs.
fn strip_kv_to_inline(kv: Node(TomlKind)) -> Node(TomlKind) {
  let children =
    list.filter(kv.children, fn(el) {
      case el {
        T(Token(kind: types.Newline, ..)) -> False
        _ -> True
      }
    })
  Node(..kv, children:, trivia: Bare)
}

/// Recursively fold every node's trailing-comment trivia back into its children,
/// immediately before the terminating newline, clearing the trailing trivia.
///
/// Statement-level lines hold their inline comment in `trivia.trailing`, but
/// greenwood traverses a node as leading-trivia → children → trailing-trivia —
/// i.e. trailing trivia comes _after_ the line's newline child. Consumers that
/// walk the tree positionally (the emitter, the validator's line/column
/// tracking) must see the source layout `value # comment\n`, so they re-inline
/// first via this function.
pub fn inline_trailing_trivia(node: Node(TomlKind)) -> Node(TomlKind) {
  let children =
    list.map(node.children, fn(el) {
      case el {
        N(n) -> N(inline_trailing_trivia(n))
        T(_) -> el
      }
    })
  case node.trivia {
    Trivia(leading:, trailing:) if trailing != [] ->
      Node(
        ..node,
        children: insert_before_first_newline(
          els: children,
          extra: list.map(trailing, T),
          acc: [],
        ),
        trivia: Trivia(leading:, trailing: []),
      )
    _ -> Node(..node, children:)
  }
}

fn insert_before_first_newline(
  els els: List(Element(TomlKind)),
  extra extra: List(Element(TomlKind)),
  acc acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case els {
    [] -> list.append(list.reverse(acc), extra)
    [first, ..rest] ->
      case first {
        T(Token(kind: types.Newline, ..)) ->
          list.append(list.reverse(acc), list.append(extra, [first, ..rest]))
        _ -> insert_before_first_newline(els: rest, extra:, acc: [first, ..acc])
      }
  }
}

/// Insert a `Comma` after the value, before any trailing whitespace / comment /
/// newline tokens.
fn insert_comma_before_trailing(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  let #(tail_rev, head_rev) =
    list.split_while(list.reverse(children), is_trailing_trivia_tok)
  list.flatten([
    list.reverse(head_rev),
    [T(Token(kind: types.Comma, text: ""))],
    list.reverse(tail_rev),
  ])
}

fn is_trailing_trivia_tok(el: Element(TomlKind)) -> Bool {
  case el {
    T(Token(kind: types.Newline, ..))
    | T(Token(kind: types.Whitespace, ..))
    | T(Token(kind: types.Comment, ..)) -> True
    _ -> False
  }
}

fn kv_has_comment(kv: Node(TomlKind)) -> Bool {
  list.any(kv.children, fn(el) {
    case el {
      T(Token(kind: types.Comment, ..)) -> True
      _ -> False
    }
  })
  || case kv.trivia {
    Trivia(leading: l, trailing: t) ->
      list.any(list.append(l, t), fn(tok) { tok.kind == types.Comment })
    Bare -> False
  }
}

/// Replace the key portion of a KV (everything before `=`) with new key
/// tokens. Preserves the `=`, the surrounding whitespace, the value, and any
/// trailing trivia (comments, newline).
pub fn rewrite_kv_key_in_place(
  kv kv: Node(TomlKind),
  new_key new_key: List(String),
) -> Node(TomlKind) {
  let after_key = value_tokens_with_equals(kv.children)
  let key_elements = case new_key {
    [single] -> [T(utils.make_key_token(single))]
    _ -> [N(greenwood.node(types.Key, builder.build_key_tokens(new_key)))]
  }
  let children =
    list.flatten([
      key_elements,
      [T(Token(kind: types.Whitespace, text: " "))],
      after_key,
    ])
  Node(..kv, children:)
}

fn ensure_separating_commas(
  items: List(Node(TomlKind)),
  layout: ArrayLayout,
) -> List(Node(TomlKind)) {
  case items {
    [] -> []
    [single] -> [single]
    [head, ..rest] -> [
      ensure_trailing_comma(head, layout),
      ..ensure_separating_commas(rest, layout)
    ]
  }
}

/// Append the separator that a non-last element is missing. Single-line arrays
/// want `, ` so neighbours read `1, 2`; multi-line arrays want `,` followed by a
/// newline so the next element starts its own line. The separator is inserted
/// after the value, before any trailing trivia the element already carries.
fn ensure_trailing_comma(
  elem: Node(TomlKind),
  layout: ArrayLayout,
) -> Node(TomlKind) {
  use <- bool.guard(has_comma_token(elem.children), return: elem)

  let separator = case layout {
    SingleLine -> [
      T(Token(kind: types.Comma, text: "")),
      T(Token(kind: types.Whitespace, text: " ")),
    ]
    MultiLine(_) -> [
      T(Token(kind: types.Comma, text: "")),
      T(Token(kind: types.Newline, text: "")),
    ]
  }

  case elem.children {
    [value, ..trailing] ->
      Node(..elem, children: list.flatten([[value], separator, trailing]))
    [] -> elem
  }
}

fn has_comma_token(children: List(Element(TomlKind))) -> Bool {
  list.any(children, fn(el) {
    case el {
      T(Token(kind: types.Comma, ..)) -> True
      _ -> False
    }
  })
}

/// Split children at (and including) the first token of the given kind.
/// Returns `#(everything-up-to-and-including-that-token, rest)`. If the
/// token isn't present, the prefix is the whole list and the rest is empty.
fn take_up_to_token(
  children: List(Element(TomlKind)),
  kind: TomlKind,
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  case children {
    [] -> #([], [])
    [T(Token(kind: k, ..)) as tok, ..rest] if k == kind -> #([tok], rest)
    [el, ..rest] -> {
      let #(prefix, after) = take_up_to_token(rest, kind)
      #([el, ..prefix], after)
    }
  }
}

fn extract_trailing_after_last(
  body: List(Element(TomlKind)),
  kind: TomlKind,
) -> List(Element(TomlKind)) {
  let match =
    list.any(body, fn(el) {
      case el {
        N(n) if n.kind == kind -> True
        _ -> False
      }
    })

  use <- bool.guard(!match, return: body)

  body
  |> list.reverse
  |> list.take_while(fn(el) {
    case el {
      N(n) if n.kind == kind -> False
      _ -> True
    }
  })
  |> list.reverse
}

/// Like `value_tokens` but includes the `=` token in the returned suffix.
fn value_tokens_with_equals(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> []
    [T(Token(kind: types.Equals, ..)), ..] -> children
    [_, ..rest] -> value_tokens_with_equals(rest)
  }
}

/// Return the child Nodes of the given `kind`, in order. Tokens and nodes of
/// other kinds are dropped.
fn child_nodes_of_kind(
  children children: List(Element(TomlKind)),
  kind kind: TomlKind,
) -> List(Node(TomlKind)) {
  list.filter_map(children, fn(el) {
    case el {
      N(n) if n.kind == kind -> Ok(n)
      _ -> Error(Nil)
    }
  })
}

fn node_has_equals(node: Node(TomlKind)) -> Bool {
  list.any(node.children, fn(el) {
    case el {
      T(Token(kind: types.Equals, ..)) -> True
      _ -> False
    }
  })
}

/// Returns True if the children list contains only trivia tokens (BOM,
/// comments, whitespace, newlines): no structural TOML content.
fn is_only_trivia(children: List(Element(TomlKind))) -> Bool {
  list.all(children, fn(el) {
    case el {
      T(Token(kind: types.Bom, ..))
      | T(Token(kind: types.Comment, ..))
      | T(Token(kind: types.Whitespace, ..))
      | T(Token(kind: types.Newline, ..)) -> True
      // A PostScript tombstone carries only document-tail trivia, so a document
      // that is nothing but tail comments still has valid (trivia-only)
      // structure — it must not be flagged NoValidTomlStructure.
      N(n) if n.kind == types.PostScript -> True
      _ -> False
    }
  })
}

/// Returns True if the children list contains at least one valid TOML
/// structural node (table, array of tables, or key-value with equals).
fn has_toml_nodes(children: List(Element(TomlKind))) -> Bool {
  list.any(children, fn(el) {
    case el {
      N(n) if n.kind == types.Table -> True
      N(n) if n.kind == types.ArrayOfTables -> True
      N(n) if n.kind == types.KeyValue -> node_has_equals(n)
      _ -> False
    }
  })
}
