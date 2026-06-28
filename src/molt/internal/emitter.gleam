//// TOML emitter: greenwood Node(TomlKind) tree → source text.
////
//// Walk the tree concatenating all token text (including trivia) in order.
//// If the source tree has not been modified, this will result in a faithful
//// round-trip.
////
//// When target version is 1.0, the emitter ensures that TOML 1.1 features are
//// not used:
////
//// - \xHH → \u00HH in basic strings
//// - \e → \u001B in basic strings
//// - HH:MM (truncated local time) → HH:MM:00
//// - Multiline inline tables → single-line
////
//// Uses string_tree for O(n) concatenation on the JavaScript target.
////
//// This also contains tree normalization functions, where whitespace nodes are
//// collapsed into an opinionated formatting approach.
////
//// Rules:
//// - `key = value` (single space around `=`)
//// - One blank line between tables/array of tables entries
//// - Leading comments after the blank line, before the header
//// - Trailing newline
//// - Canonical inline interiors: arrays as `[1, 2, 3]` (comma+space, no
////   bracket padding), inline tables as `{ a = 1, b = 2 }` (padded), recursing
////   through nesting. A comment-free multiline array/table collapses to a
////   single line; any interior comment preserves the value verbatim.
//// - No indentation, no key sorting, no quote style changes

import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/string_tree.{type StringTree}
import greenwood.{
  type Element, type Node, type Token, type Trivia, Bare, Continue, Node,
  NodeElement as N, Token, TokenElement as T, Trivia,
}
import molt/internal/cst/elements
import molt/types.{type TomlKind}

/// Normalize a document tree, returning a new tree with normalized formatting.
pub fn normalize(node: Node(TomlKind)) -> Node(TomlKind) {
  let children = normalize_top_level(node.children, True)
  // Ensure trailing newline
  let children = ensure_trailing_newline(children)
  // Preserve the root's own trivia (e.g. document-head leading comments) rather
  // than wiping it — normalize should only drop trivia where it must.
  Node(..node, children:)
}

/// Emit a TOML document tree as TOML 1.1 source text.
pub fn emit(node: Node(TomlKind)) -> String {
  emit_versioned(node:, version: types.v1_1)
}

const newline = Token(kind: types.Newline, text: "\n")

/// Ensure a document-head comment is separated from the first statement by a
/// blank line, so it round-trips as a head comment: the parser only routes a
/// blank-separated leading comment block to the document head. No-op when there
/// is no head comment, no following statement, or the blank is already present
/// (so unedited parsed documents are untouched). The inserted newline matches
/// the document's line-ending style.
fn ensure_head_separation(node: Node(TomlKind)) -> Node(TomlKind) {
  case node.trivia {
    Trivia(leading:, trailing:) ->
      case
        leading_has_comment(leading)
        && has_statement_child(node.children)
        && !head_separated(leading)
      {
        True ->
          Node(
            ..node,
            trivia: Trivia(
              leading: list.append(leading, [
                Token(kind: types.Newline, text: ""),
              ]),
              trailing:,
            ),
          )
        False -> node
      }
    Bare -> node
  }
}

/// Resolve every synthesized newline — a `Newline` token carrying empty text,
/// produced by the builders / comment setters — to the document's actual newline
/// style `nl`. Newlines that already carry text (everything from parsing) are
/// left untouched, so an unedited document still round-trips byte-for-byte and a
/// document with mixed line endings keeps each one verbatim.
fn resolve_newlines(node: Node(TomlKind), nl: String) -> Node(TomlKind) {
  let children =
    list.map(node.children, fn(el) {
      case el {
        T(tok) -> T(resolve_newline_token(tok, nl))
        N(n) -> N(resolve_newlines(n, nl))
      }
    })
  let trivia = case node.trivia {
    Bare -> Bare
    Trivia(leading:, trailing:) ->
      Trivia(
        leading: list.map(leading, resolve_newline_token(_, nl)),
        trailing: list.map(trailing, resolve_newline_token(_, nl)),
      )
  }
  Node(kind: node.kind, children:, trivia:)
}

fn resolve_newline_token(tok: Token(TomlKind), nl: String) -> Token(TomlKind) {
  case tok.kind, tok.text {
    types.Newline, "" -> Token(..tok, text: nl)
    _, _ -> tok
  }
}

fn leading_has_comment(tokens: List(Token(TomlKind))) -> Bool {
  list.any(tokens, fn(t) { t.kind == types.Comment })
}

fn has_statement_child(children: List(Element(TomlKind))) -> Bool {
  list.any(children, fn(el) {
    case el {
      N(n) -> n.kind != types.PostScript
      T(_) -> False
    }
  })
}

/// True when the leading trivia already ends in a blank line (the head comment's
/// own terminating newline plus at least one more), i.e. two trailing newlines
/// ignoring intervening whitespace.
fn head_separated(leading: List(Token(TomlKind))) -> Bool {
  trailing_newline_run(list.reverse(leading)) >= 2
}

fn trailing_newline_run(rev: List(Token(TomlKind))) -> Int {
  case rev {
    [Token(kind: types.Newline, ..), ..rest] -> 1 + trailing_newline_run(rest)
    [Token(kind: types.Whitespace, ..), ..rest] -> trailing_newline_run(rest)
    _ -> 0
  }
}

/// Emit a TOML document tree as source text.
pub fn emit_versioned(
  node node: Node(TomlKind),
  version version: types.TomlVersion,
) -> String {
  case version == types.v1_0 {
    True -> emit_v1_0(node)
    False -> emit_v1_1(node)
  }
}

fn emit_v1_1(node: Node(TomlKind)) -> String {
  let nl = elements.document_newline(node)
  let node =
    node
    |> ensure_head_separation
    |> resolve_newlines(nl)
    |> elements.inline_trailing_trivia
  let visitor =
    greenwood.visitor()
    |> greenwood.on_trivia(fn(tree, tok) {
      Continue(emit_token_v1_1(tree, tok))
    })
    |> greenwood.on_token(fn(tree, tok) { Continue(emit_token_v1_1(tree, tok)) })

  greenwood.traverse(over: node, from: string_tree.new(), visitor:)
  |> string_tree.to_string
}

/// v1.0 emit state: tracks inline table depth, a pending comma, and whether
/// we are immediately after an open brace (so an empty table stays `{}`).
type EmitState {
  EmitState(
    tree: StringTree,
    inline_depth: Int,
    depth: Int,
    pending_comma: Bool,
    pending_open: Bool,
  )
}

fn emit_v1_0(node: Node(TomlKind)) -> String {
  let nl = elements.document_newline(node)
  let node =
    node
    |> ensure_head_separation
    |> resolve_newlines(nl)
    |> elements.inline_trailing_trivia
  let visitor =
    greenwood.visitor()
    |> greenwood.on_trivia(fn(state, tok) {
      Continue(emit_v1_0_token(state, tok))
    })
    |> greenwood.on_token(fn(state, tok) {
      Continue(emit_v1_0_token(state, tok))
    })
    |> greenwood.on_enter_node(fn(state, node) {
      let state = EmitState(..state, depth: state.depth + 1)
      case node.kind == types.InlineTable && is_multiline_inline_table(node) {
        True ->
          Continue(EmitState(..state, inline_depth: state.inline_depth + 1))
        False -> Continue(state)
      }
    })
    |> greenwood.on_exit_node(fn(state, node) {
      let state = EmitState(..state, depth: state.depth - 1)
      case node.kind == types.InlineTable && is_multiline_inline_table(node) {
        True ->
          Continue(EmitState(..state, inline_depth: state.inline_depth - 1))
        False -> Continue(state)
      }
    })

  let state =
    greenwood.traverse(
      over: node,
      from: EmitState(
        tree: string_tree.new(),
        inline_depth: 0,
        depth: 0,
        pending_comma: False,
        pending_open: False,
      ),
      visitor:,
    )
  string_tree.to_string(state.tree)
}

fn emit_v1_0_token(state: EmitState, tok: Token(TomlKind)) -> EmitState {
  case state.inline_depth > 0, tok.kind {
    // Inside inline table: skip newlines, comments, and whitespace
    True, types.Newline -> state
    True, types.Comment -> state
    True, types.Whitespace -> state
    // Buffer comma — only emit if next token isn't }
    True, types.Comma -> EmitState(..state, pending_comma: True)
    // RightBrace: emit a padded `}`, except for an empty table (`{}`), where
    // `pending_open` is still set because nothing was emitted after the `{`.
    True, types.RightBrace -> {
      let tree = case state.pending_open {
        True -> string_tree.append(state.tree, "}")
        False -> string_tree.append(state.tree, " }")
      }
      EmitState(..state, tree:, pending_comma: False, pending_open: False)
    }
    // LeftBrace: emit `{` and arm padding for the first entry (or `{}`)
    True, types.LeftBrace -> {
      let state = flush_pending(state)
      let tree = string_tree.append(state.tree, "{")
      EmitState(..state, tree:, pending_open: True)
    }
    // Equals: emit with spaces around it
    True, types.Equals -> {
      let tree = string_tree.append(state.tree, " = ")
      EmitState(..state, tree:)
    }
    // Any other token inside inline table: flush pending separator, emit
    True, _ -> {
      let state = flush_pending(state)
      let tree = emit_token_text_v1_0(state.tree, tok)
      EmitState(..state, tree:)
    }
    // Outside inline table: emit with v1.0 transforms
    False, _ -> {
      let tree = emit_token_text_v1_0(state.tree, tok)
      EmitState(..state, tree:)
    }
  }
}

/// Emit the separator owed to the next entry: a single space after an open
/// brace, or `, ` after a buffered comma. At most one can be pending.
fn flush_pending(state: EmitState) -> EmitState {
  case state.pending_open, state.pending_comma {
    True, _ -> {
      let tree = string_tree.append(state.tree, " ")
      EmitState(..state, tree:, pending_open: False)
    }
    _, True -> {
      let tree = string_tree.append(state.tree, ", ")
      EmitState(..state, tree:, pending_comma: False)
    }
    _, _ -> state
  }
}

/// Emit a token with v1.0 transforms (string escapes, time padding).
fn emit_token_text_v1_0(tree: StringTree, tok: Token(TomlKind)) -> StringTree {
  case tok.kind {
    types.BasicString -> {
      let text = "\"" <> tok.text <> "\""
      string_tree.append_tree(tree, rewrite_v1_0_escapes(text))
    }
    types.MultilineBasicString -> {
      let text = "\"\"\"" <> tok.text <> "\"\"\""
      string_tree.append_tree(tree, rewrite_v1_0_escapes(text))
    }
    types.MultilineBasicStringNl -> {
      let text = "\"\"\"\n" <> tok.text <> "\"\"\""
      string_tree.append_tree(tree, rewrite_v1_0_escapes(text))
    }
    types.LocalTime -> string_tree.append(tree, pad_local_time(tok.text))
    _ -> emit_token_common(tree, tok)
  }
}

/// Emit a token as v1.1 (no transforms).
fn emit_token_v1_1(tree: StringTree, tok: Token(TomlKind)) -> StringTree {
  case tok.kind {
    types.BasicString -> string_tree.append(tree, "\"" <> tok.text <> "\"")
    types.MultilineBasicString ->
      string_tree.append(tree, "\"\"\"" <> tok.text <> "\"\"\"")
    types.MultilineBasicStringNl ->
      string_tree.append(tree, "\"\"\"\n" <> tok.text <> "\"\"\"")
    _ -> emit_token_common(tree, tok)
  }
}

/// Token emission shared between v1.0 and v1.1 (fixed-text tokens, literals, etc.)
fn emit_token_common(tree: StringTree, tok: Token(TomlKind)) -> StringTree {
  case tok.kind {
    types.Equals -> string_tree.append(tree, "=")
    types.Dot -> string_tree.append(tree, ".")
    types.Comma -> string_tree.append(tree, ",")
    types.LeftBracket -> string_tree.append(tree, "[")
    types.RightBracket -> string_tree.append(tree, "]")
    types.LeftBrace -> string_tree.append(tree, "{")
    types.RightBrace -> string_tree.append(tree, "}")
    types.BoolTrue -> string_tree.append(tree, "true")
    types.BoolFalse -> string_tree.append(tree, "false")
    types.Inf -> string_tree.append(tree, "inf")
    types.PosInf -> string_tree.append(tree, "+inf")
    types.NegInf -> string_tree.append(tree, "-inf")
    types.NaN -> string_tree.append(tree, "nan")
    types.PosNaN -> string_tree.append(tree, "+nan")
    types.NegNaN -> string_tree.append(tree, "-nan")
    types.LiteralString -> string_tree.append(tree, "'" <> tok.text <> "'")
    types.MultilineLiteralString ->
      string_tree.append(tree, "'''" <> tok.text <> "'''")
    types.MultilineLiteralStringNl ->
      string_tree.append(tree, "'''\n" <> tok.text <> "'''")
    _ -> string_tree.append(tree, tok.text)
  }
}

/// Rewrite \e → \u001B and \xHH → \u00HH in string token text.
fn rewrite_v1_0_escapes(text: String) -> StringTree {
  do_rewrite_v1_0_escapes(string.to_graphemes(text), string_tree.new())
}

fn do_rewrite_v1_0_escapes(
  chars: List(String),
  tree: StringTree,
) -> StringTree {
  case chars {
    [] -> tree
    ["\\", "e", ..rest] ->
      do_rewrite_v1_0_escapes(rest, string_tree.append(tree, "\\u001B"))
    ["\\", "x", h1, h2, ..rest] ->
      do_rewrite_v1_0_escapes(
        rest,
        string_tree.append(tree, "\\u00" <> h1 <> h2),
      )
    [ch, ..rest] -> do_rewrite_v1_0_escapes(rest, string_tree.append(tree, ch))
  }
}

/// Pad HH:MM to HH:MM:00 for TOML 1.0.
fn pad_local_time(text: String) -> String {
  use <- bool.guard(string.length(text) == 5, return: text <> ":00")
  text
}

/// Check whether an inline table uses TOML 1.1 multiline syntax — i.e. it has a
/// newline at its *own* structural level (between the braces, around entries).
///
/// Newlines that occur *within* a nested array or inline-table value are legal
/// in TOML 1.0 — the spec forbids newlines between the curly braces "unless they
/// are valid within a value" — so they must NOT trigger a v1.0 collapse. This
/// walks the table's structure but does not descend into nested array/inline
/// table interiors (it still checks their surrounding trivia, e.g. a newline
/// between `=` and the value). Multiline strings keep their newlines inside the
/// token text rather than as `Newline` tokens, so they are naturally excluded.
fn is_multiline_inline_table(node: Node(TomlKind)) -> Bool {
  has_structural_newline(node.children)
}

fn has_structural_newline(elements: List(Element(TomlKind))) -> Bool {
  list.any(elements, fn(el) {
    case el {
      T(Token(kind: types.Newline, ..)) -> True
      T(_) -> False
      N(n) ->
        case n.kind {
          types.Array | types.InlineTable -> trivia_has_newline(n.trivia)
          _ ->
            trivia_has_newline(n.trivia) || has_structural_newline(n.children)
        }
    }
  })
}

fn trivia_has_newline(trivia: Trivia(TomlKind)) -> Bool {
  case trivia {
    Bare -> False
    Trivia(leading:, trailing:) ->
      list.any(leading, is_newline_token)
      || list.any(trailing, is_newline_token)
  }
}

fn is_newline_token(tok: Token(TomlKind)) -> Bool {
  tok.kind == types.Newline
}

fn normalize_top_level(
  children: List(Element(TomlKind)),
  first: Bool,
) -> List(Element(TomlKind)) {
  case children {
    [] -> []
    [el, ..rest] ->
      case el {
        N(n) if n.kind == types.Table || n.kind == types.ArrayOfTables ->
          normalize_table_node(node: n, first:, rest:)
        N(n) if n.kind == types.KeyValue -> [
          N(normalize_kv_node(n)),
          ..normalize_top_level(rest, False)
        ]

        N(n) if n.kind == types.PostScript ->
          normalize_postscript(node: n, first:, rest:)
        T(Token(kind: types.Comment, ..)) -> [
          el,
          T(newline),
          ..normalize_top_level(rest, first)
        ]
        _ -> normalize_top_level(rest, first)
      }
  }
}

fn normalize_table_node(
  node node: Node(TomlKind),
  first first: Bool,
  rest rest: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  let sep = case first {
    True -> []
    False -> [T(newline)]
  }

  // Rebuild: header line + newline + normalized body KVs
  let header_tokens = extract_header_tokens(node.children)
  let comment = extract_inline_comment(node.children)
  let body = normalize_body(node.children)
  let header_line = case comment {
    "" -> list.flatten([header_tokens, [T(newline)]])
    c ->
      list.flatten([
        header_tokens,
        [
          T(Token(kind: types.Whitespace, text: " ")),
          T(Token(kind: types.Comment, text: c)),
          T(newline),
        ],
      ])
  }
  let children = list.flatten([header_line, body])

  // Preserve leading comments as trivia
  let trivia = normalize_trivia(node)
  let normalized = Node(..node, children:, trivia:)

  list.flatten([
    sep,
    [N(normalized)],
    normalize_top_level(rest, False),
  ])
}

fn normalize_kv_node(node: Node(TomlKind)) -> Node(TomlKind) {
  let #(key_side, _) = elements.split_at_equals(node.children)
  let key_elements =
    list.filter(key_side, fn(el) {
      case el {
        T(Token(kind: types.Whitespace, ..)) -> False
        _ -> True
      }
    })
  let value_el =
    elements.value_tokens(node.children)
    |> elements.find_first_value
    |> option.map(normalize_value_el)
  let comment = extract_inline_comment(node.children)
  let value_part = case value_el, comment {
    Some(el), "" -> [el, T(newline)]
    Some(el), c -> [
      el,
      T(Token(kind: types.Whitespace, text: " ")),
      T(Token(kind: types.Comment, text: c)),
      T(newline),
    ]
    None, _ -> [T(newline)]
  }
  let children =
    list.flatten([
      key_elements,
      [
        T(Token(kind: types.Whitespace, text: " ")),
        T(Token(kind: types.Equals, text: "")),
        T(Token(kind: types.Whitespace, text: " ")),
      ],
      value_part,
    ])
  Node(..node, children:, trivia: normalize_trivia(node))
}

// The PostScript tombstone holds document-tail comments as its own leading
// trivia. Canonicalize them like any node's leading comments (keep the comment
// lines, drop blank-only trivia), and — like a table header — separate them
// from the preceding content with a single blank line. A tombstone with no
// comments left is dropped entirely.
fn normalize_postscript(
  node node: Node(TomlKind),
  first first: Bool,
  rest rest: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case normalize_trivia(node) {
    Bare -> normalize_top_level(rest, first)
    Trivia(leading:, trailing:) -> {
      let leading = case first {
        True -> leading
        False -> [newline, ..leading]
      }
      [
        N(Node(..node, children: [], trivia: Trivia(leading:, trailing:))),
        ..normalize_top_level(rest, first)
      ]
    }
  }
}

/// Recursively normalize a value element.
///
/// Inline arrays and inline tables that contain no comments are rebuilt into
/// canonical single-line form (`[1, 2, 3]`, `{ a = 1, b = 2 }`), recursing into
/// their contents. Anything containing a comment is preserved verbatim — the
/// library exists to keep comments, so it never collapses a commented layout.
/// Scalars pass through unchanged.
fn normalize_value_el(el: Element(TomlKind)) -> Element(TomlKind) {
  case el {
    N(n) ->
      case n.kind {
        types.Array ->
          case contains_comment(n) {
            True -> el
            False -> N(canonical_array(n))
          }
        types.InlineTable ->
          case contains_comment(n) {
            True -> el
            False -> N(canonical_inline_table(n))
          }
        _ -> el
      }
    _ -> el
  }
}

/// True if a comment appears anywhere in the node's subtree, whether as an
/// inline child token or attached as leading/trailing trivia. Trailing comments
/// live in `trivia.trailing`, so a children-only scan would miss them and
/// wrongly collapse a commented inline table or array.
fn contains_comment(node: Node(TomlKind)) -> Bool {
  trivia_has_comment(node.trivia)
  || list.any(node.children, fn(el) {
    case el {
      T(Token(kind: types.Comment, ..)) -> True
      T(_) -> False
      N(child) -> contains_comment(child)
    }
  })
}

fn trivia_has_comment(trivia: Trivia(TomlKind)) -> Bool {
  case trivia {
    Bare -> False
    Trivia(leading:, trailing:) ->
      list.any(list.append(leading, trailing), fn(t) { t.kind == types.Comment })
  }
}

/// Rebuild a comment-free Array node as `[v1, v2, v3]` (no bracket padding),
/// recursively normalizing each element value. Empty becomes `[]`.
///
/// Each value is wrapped in an `ArrayElement` node with its separating comma and
/// space held _inside_ the element: the shape the parser and validator expect
/// (a bare `Comma` at array level is a `MisplacedArraySeparator`).
fn canonical_array(node: Node(TomlKind)) -> Node(TomlKind) {
  let values =
    elements.extract_array_items(node)
    |> list.filter_map(fn(item) {
      case elements.find_first_value(item.children) {
        Some(v) -> Ok(normalize_value_el(v))
        None -> Error(Nil)
      }
    })
  let item_count = list.length(values)
  let item_elements =
    list.index_map(values, fn(v, i) {
      let last = i == item_count - 1
      N(canonical_array_element(v, last:))
    })
  let children =
    list.flatten([
      [T(Token(kind: types.LeftBracket, text: "["))],
      item_elements,
      [T(Token(kind: types.RightBracket, text: "]"))],
    ])
  Node(..node, children:, trivia: Bare)
}

/// Wrap a value in an `ArrayElement`. Non-last elements carry a trailing
/// `, ` (comma + space) so the rebuilt array reads `[1, 2, 3]`.
fn canonical_array_element(
  value: Element(TomlKind),
  last last: Bool,
) -> Node(TomlKind) {
  let children = case last {
    True -> [value]
    False -> [
      value,
      T(Token(kind: types.Comma, text: ",")),
      T(Token(kind: types.Whitespace, text: " ")),
    ]
  }
  Node(kind: types.ArrayElement, children:, trivia: Bare)
}

/// Rebuild a comment-free InlineTable node as `{ k = v, ... }` (padded inside
/// the braces), recursively normalizing each entry value. Empty becomes `{}`.
fn canonical_inline_table(node: Node(TomlKind)) -> Node(TomlKind) {
  let entries =
    elements.extract_inline_entries(node)
    |> list.map(normalize_inline_kv)
  let children = case entries {
    [] -> [
      T(Token(kind: types.LeftBrace, text: "{")),
      T(Token(kind: types.RightBrace, text: "}")),
    ]
    _ ->
      list.flatten([
        [
          T(Token(kind: types.LeftBrace, text: "{")),
          T(Token(kind: types.Whitespace, text: " ")),
        ],
        interpose_separated(entries),
        [
          T(Token(kind: types.Whitespace, text: " ")),
          T(Token(kind: types.RightBrace, text: "}")),
        ],
      ])
  }
  Node(..node, children:, trivia: Bare)
}

/// Rebuild a single inline-table entry as `key = value` (no trailing comma or
/// newline: separators are added by `canonical_inline_table`). Safe to assume
/// no trailing comment, since the enclosing table is comment-free.
fn normalize_inline_kv(kv: Node(TomlKind)) -> Element(TomlKind) {
  let #(key_side, _) = elements.split_at_equals(kv.children)
  let key_elements =
    list.filter(key_side, fn(el) {
      case el {
        T(Token(kind: types.Whitespace, ..)) -> False
        _ -> True
      }
    })
  let value_part =
    elements.value_tokens(kv.children)
    |> elements.find_first_value
    |> option.map(fn(v) { [normalize_value_el(v)] })
    |> option.unwrap([])
  let children =
    list.flatten([
      key_elements,
      [
        T(Token(kind: types.Whitespace, text: " ")),
        T(Token(kind: types.Equals, text: "")),
        T(Token(kind: types.Whitespace, text: " ")),
      ],
      value_part,
    ])
  N(Node(..kv, children:, trivia: Bare))
}

/// Interpose `, ` between elements (comma token + single space).
fn interpose_separated(
  elements: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case elements {
    [] -> []
    [single] -> [single]
    [head, ..rest] -> [
      head,
      T(Token(kind: types.Comma, text: ",")),
      T(Token(kind: types.Whitespace, text: " ")),
      ..interpose_separated(rest)
    ]
  }
}

fn normalize_trivia(node: Node(TomlKind)) -> Trivia(TomlKind) {
  case node.trivia {
    Bare -> Bare
    Trivia(leading:, trailing:) -> {
      let comments =
        list.filter_map(leading, fn(t) {
          case t.kind {
            types.Comment ->
              Ok([
                Token(kind: types.Comment, text: t.text),
                newline,
              ])
            _ -> Error(Nil)
          }
        })
        |> list.flatten

      // Preserve a trailing inline comment, canonicalizing it to a single
      // space before the `#`.
      let trailing = case find_trailing_comment_text(trailing) {
        Some(text) -> [
          Token(kind: types.Whitespace, text: " "),
          Token(kind: types.Comment, text:),
        ]
        None -> []
      }

      case comments, trailing {
        [], [] -> Bare
        _, _ -> Trivia(leading: comments, trailing:)
      }
    }
  }
}

fn find_trailing_comment_text(
  tokens: List(Token(TomlKind)),
) -> option.Option(String) {
  list.find_map(tokens, fn(t) {
    case t.kind {
      types.Comment -> Ok(t.text)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn extract_header_tokens(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  list.filter_map(children, fn(el) {
    case el {
      T(Token(kind: types.LeftBracket, ..)) -> Ok(el)
      T(Token(kind: types.RightBracket, ..)) -> Ok(el)
      T(Token(kind: types.Dot, ..)) -> Ok(el)
      T(Token(kind: types.BareKey, ..)) -> Ok(el)
      T(Token(kind: types.BasicString, ..)) -> Ok(el)
      T(Token(kind: types.LiteralString, ..)) -> Ok(el)
      T(Token(kind: types.Integer, ..)) -> Ok(el)
      _ -> Error(Nil)
    }
  })
}

fn normalize_body(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  list.filter_map(children, fn(el) {
    case el {
      N(n) if n.kind == types.KeyValue -> Ok(N(normalize_kv_node(n)))
      _ -> Error(Nil)
    }
  })
}

fn extract_inline_comment(children: List(Element(TomlKind))) -> String {
  case children {
    [] -> ""
    [T(Token(kind: types.Comment, text:)), ..] -> text
    [_, ..rest] -> extract_inline_comment(rest)
  }
}

fn ensure_trailing_newline(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  use <- bool.guard(last_ends_with_newline(children), return: children)
  list.append(children, [T(newline)])
}

fn last_ends_with_newline(children: List(Element(TomlKind))) -> Bool {
  case list.last(children) {
    Ok(T(Token(kind: types.Newline, ..))) -> True
    Ok(N(node)) -> last_ends_with_newline(node.children)
    _ -> False
  }
}
