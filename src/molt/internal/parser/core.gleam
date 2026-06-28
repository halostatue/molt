import gleam/list
import gleam/option
import greenwood.{
  type Element, type Node, type Token, Bare, Node, NodeElement as N, Token,
  TokenElement as T, Trivia,
}
import molt/error.{type MoltError}
import molt/internal/classifier
import molt/internal/utils
import molt/types.{type TomlKind}
import splitter

pub type Splitters {
  Splitters(
    line: splitter.Splitter,
    key: splitter.Splitter,
    value: splitter.Splitter,
    basic_str: splitter.Splitter,
    literal_str: splitter.Splitter,
    ml_basic: splitter.Splitter,
    ml_literal: splitter.Splitter,
  )
}

/// The current table being built.
pub type CurrentTable {
  NoTable
  Building(
    kind: TomlKind,
    /// Header + body children, reverse-ordered.
    children: List(Element(TomlKind)),
    /// Leading trivia attached to this table, reverse-ordered.
    trivia: List(Token(TomlKind)),
    /// The header line's trailing inline comment (`[t] # c`), reverse-ordered.
    trailing: List(Token(TomlKind)),
  )
}

pub type State {
  State(
    sp: Splitters,
    /// Pending trivia (comments + blank lines) awaiting attachment to the
    /// next non-trivia node, reverse-ordered.
    pending_trivia: List(Token(TomlKind)),
    /// Document-head trivia routed to the Root node's own leading trivia: a
    /// leading comment block separated from the first statement by a blank line.
    /// Reverse-ordered.
    root_leading: List(Token(TomlKind)),
    /// The leading UTF-8 BOM token, if present, or `[]`. Kept as the first token
    /// of Root's leading trivia (it is document-head trivia, like head comments,
    /// and must emit before them) rather than as a child node.
    bom: List(Token(TomlKind)),
    /// Document-level elements, reverse-ordered.
    doc_acc: List(Element(TomlKind)),
    current_table: CurrentTable,
    error: Result(Nil, MoltError),
  )
}

pub fn new_state(bom: String) -> State {
  let bom = case bom {
    "\u{FEFF}" -> [greenwood.token(types.Bom, "\u{FEFF}")]
    _ -> []
  }

  State(
    sp: new_splitters(),
    pending_trivia: [],
    root_leading: [],
    bom:,
    doc_acc: [],
    current_table: NoTable,
    error: Ok(Nil),
  )
}

pub fn peek_first_significant(line: String) -> String {
  case line {
    " " <> r | "\t" <> r -> peek_first_significant(r)
    _ -> line
  }
}

/// Scan a contiguous whitespace run. Returns the full run text and the input
/// after it.
pub fn take_ws(input: String) -> #(String, String) {
  do_scan_ws(input, [])
}

/// Scan a contiguous whitespace run. `first` is the already-consumed delimiter
/// character (one of " " or "\t"); `rest` is the remainder. Returns the full
/// run text and the input after it.
pub fn scan_ws(first first: String, rest rest: String) -> #(String, String) {
  do_scan_ws(rest, [first])
}

/// Classifies an as-yet unknown non-string value as a boolean, a special float,
/// a date/time type, a number type, or invalid.
pub fn tokenize_value(text: String) -> Token(TomlKind) {
  classifier.match_type(text)
  |> option.map(greenwood.token(_, text))
  |> option.lazy_unwrap(fn() { greenwood.token(types.InvalidValue, text) })
}

pub fn finalize(state: State) -> Result(Node(TomlKind), e) {
  let doc = flush_current_table(state)
  let node = case doc, state.pending_trivia {
    // No dangling trivia: just the accumulated document elements. Any
    // document-head block lives on Root's own leading trivia.
    _, [] -> root_node(children: doc, leading: state.root_leading)

    // An otherwise-empty document (only comments and/or blank lines): attach the
    // trivia as the Root node's leading trivia so document-head comments are
    // readable and editable as the `Head` tombstone. As Bare child tokens they
    // would round-trip but be invisible to the comment API. `pending` is
    // reverse-ordered, which `reverse_tree` flips back to source order. The head
    // split never runs without a first node, so `root_leading` is empty here.
    [], pending -> root_node(children: [], leading: pending)

    // The document has content, so the pending trivia dangles after the last
    // node. Home it on a `PostScript` tombstone (the document's last child)
    // whose leading trivia holds the comments, mirroring how Root holds
    // document-head trivia. This makes tail comments addressable through
    // `get_document_comments(_, Tail)`. `pending` is reverse-ordered, which
    // `reverse_tree` flips back to source order.
    _, pending -> {
      let postscript =
        greenwood.node_with_trivia(
          kind: types.PostScript,
          children: [],
          trivia: Trivia(leading: pending, trailing: []),
        )
      root_node(children: [N(postscript), ..doc], leading: state.root_leading)
    }
  }
  node
  |> reverse_tree()
  |> prepend_bom(state.bom)
  |> Ok
}

/// Prepend the BOM (if any) as the first token of Root's leading trivia, so it
/// emits before any document-head comment. Runs after `reverse_tree`, so both
/// `bom` and the existing leading trivia are already in source order.
fn prepend_bom(
  node: Node(TomlKind),
  bom: List(Token(TomlKind)),
) -> Node(TomlKind) {
  case bom {
    [] -> node
    _ -> {
      let #(leading, trailing) = case node.trivia {
        Bare -> #([], [])
        Trivia(leading:, trailing:) -> #(leading, trailing)
      }
      Node(
        ..node,
        trivia: Trivia(leading: list.append(bom, leading), trailing:),
      )
    }
  }
}

/// Build the Root node with the given reverse-ordered children and document-head
/// leading trivia (Bare when there is none).
fn root_node(
  children children: List(Element(TomlKind)),
  leading leading: List(Token(TomlKind)),
) -> Node(TomlKind) {
  case leading {
    [] -> greenwood.node(types.Root, children)
    _ ->
      greenwood.node_with_trivia(
        kind: types.Root,
        children:,
        trivia: Trivia(leading:, trailing: []),
      )
  }
}

/// Split a first node's reverse-ordered pending trivia into the part that
/// belongs to the document head (Root) and the part that stays on the node.
///
/// A leading comment block separated from the content by a blank line is a
/// document-head comment: the comment block AND the terminating blank run move
/// to Root, and only the comment block adjacent to the node (the comments after
/// the blank) stay on the node. With no separating blank — i.e. no comment sits
/// above a blank line — nothing moves. The split is a pure token redistribution,
/// so the document still round-trips byte-for-byte. Returns `#(root_rev,
/// node_rev)`, both reverse-ordered.
pub fn peel_head_block(
  pending_rev: List(Token(TomlKind)),
) -> #(List(Token(TomlKind)), List(Token(TomlKind))) {
  let lines = group_lines(list.reverse(pending_rev))
  let #(root_lines, node_lines) = split_off_node_block(lines)
  case list.any(root_lines, is_comment_line) {
    False -> #([], pending_rev)
    True -> #(
      list.reverse(list.flatten(root_lines)),
      list.reverse(list.flatten(node_lines)),
    )
  }
}

/// Group source-ordered trivia tokens into physical lines, each ending with its
/// terminating `Newline` token (a final line without a newline is kept whole).
fn group_lines(tokens: List(Token(TomlKind))) -> List(List(Token(TomlKind))) {
  do_group_lines(tokens:, current_rev: [], acc_rev: [])
}

fn do_group_lines(
  tokens tokens: List(Token(TomlKind)),
  current_rev current_rev: List(Token(TomlKind)),
  acc_rev acc_rev: List(List(Token(TomlKind))),
) -> List(List(Token(TomlKind))) {
  case tokens {
    [] ->
      case current_rev {
        [] -> list.reverse(acc_rev)
        _ -> list.reverse([list.reverse(current_rev), ..acc_rev])
      }
    [t, ..rest] -> {
      let current_rev = [t, ..current_rev]
      case t.kind {
        types.Newline ->
          do_group_lines(tokens: rest, current_rev: [], acc_rev: [
            list.reverse(current_rev),
            ..acc_rev
          ])
        _ -> do_group_lines(tokens: rest, current_rev:, acc_rev:)
      }
    }
  }
}

/// Partition lines into `#(root_lines, node_lines)` where `node_lines` is the
/// maximal trailing run of comment lines (those adjacent to the node, after the
/// last blank line) and `root_lines` is everything before it.
fn split_off_node_block(
  lines: List(List(Token(TomlKind))),
) -> #(List(List(Token(TomlKind))), List(List(Token(TomlKind)))) {
  let rev = list.reverse(lines)
  let node_rev = list.take_while(rev, is_comment_line)
  let root_rev = list.drop(rev, list.length(node_rev))
  #(list.reverse(root_rev), list.reverse(node_rev))
}

fn is_comment_line(line: List(Token(TomlKind))) -> Bool {
  list.any(line, fn(t) { t.kind == types.Comment })
}

/// Split a line's trailing inline comment off the front of a reverse-ordered
/// child list, returning the remaining children and the comment tokens (also
/// reverse-ordered, so `reverse_tree` flips them to `[Whitespace?, Comment]`).
///
/// TOML is line-oriented, so a line's trailing comment is exactly the
/// `[Whitespace?, Comment]` run immediately before its terminating newline (or
/// at the end of the line at EOF). The line builders call this so trailing
/// comments are attached to `trivia.trailing` during parsing rather than in a
/// later pass. Comments inside multi-line values stay in those value nodes.
pub fn peel_trailing_comment_rev(
  children_rev: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Token(TomlKind))) {
  case children_rev {
    [
      T(Token(kind: types.Newline, ..)) as nl,
      T(Token(kind: types.Comment, ..) as comment),
      T(Token(kind: types.Whitespace, ..) as ws),
      ..rest
    ] -> #([nl, ..rest], [comment, ws])
    [
      T(Token(kind: types.Newline, ..)) as nl,
      T(Token(kind: types.Comment, ..) as comment),
      ..rest
    ] -> #([nl, ..rest], [comment])
    [
      T(Token(kind: types.Comment, ..) as comment),
      T(Token(kind: types.Whitespace, ..) as ws),
      ..rest
    ] -> #(rest, [comment, ws])
    [T(Token(kind: types.Comment, ..) as comment), ..rest] -> #(rest, [comment])
    _ -> #(children_rev, [])
  }
}

/// Walk the tree and reverse each node's children and trivia. This is the
/// single normalization pass: the parser uses reverse-only accumulators
/// throughout and we undo that here.
fn reverse_tree(node: Node(TomlKind)) -> Node(TomlKind) {
  let children =
    node.children
    |> list.reverse
    |> list.map(reverse_element)
  let trivia = case node.trivia {
    Bare -> Bare
    Trivia(leading: l, trailing: t) ->
      Trivia(leading: list.reverse(l), trailing: list.reverse(t))
  }

  Node(kind: node.kind, children:, trivia:)
}

fn reverse_element(el: Element(TomlKind)) -> Element(TomlKind) {
  case el {
    T(_) -> el
    N(n) -> N(reverse_tree(n))
  }
}

fn do_scan_ws(input: String, acc: List(String)) -> #(String, String) {
  case input, acc {
    " " <> rest, _ -> do_scan_ws(rest, [" ", ..acc])
    "\t" <> rest, _ -> do_scan_ws(rest, ["\t", ..acc])
    _, [] -> #("", input)
    _, _ -> #(utils.reverse_concat(acc), input)
  }
}

pub fn flush_current_table(state: State) -> List(Element(TomlKind)) {
  case state.current_table {
    NoTable -> state.doc_acc
    Building(kind:, children:, trivia: leading, trailing:) -> {
      let trivia = case leading, trailing {
        [], [] -> Bare
        _, _ -> Trivia(leading:, trailing:)
      }
      [
        N(greenwood.node_with_trivia(kind:, children:, trivia:)),
        ..state.doc_acc
      ]
    }
  }
}

fn new_splitters() -> Splitters {
  Splitters(
    line: splitter.new(["\r\n", "\n", "\r"]),
    key: splitter.new(["=", ".", " ", "\t", "\"", "'", "[", "]", "#"]),
    value: splitter.new([
      ",", "[", "]", "{", "}", "\"", "'", "#", " ", "\t", "=",
    ]),
    basic_str: splitter.new(["\\", "\""]),
    literal_str: splitter.new(["'"]),
    ml_basic: splitter.new(["\"\"\"", "\\"]),
    ml_literal: splitter.new(["'''"]),
  )
}
