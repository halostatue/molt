//// Molt's TOML parser.
////
//// This is an optimized recursive descent parser that combines scanning and
//// tokenization into a single step. The optimization begins with TOML being
//// a line-oriented format, where table headers, table array headers, and
//// key-value assignments must be on a single line with only whitespace leading
//// and comments following.
////
//// It uses multiple [splitter][splitter] instances to efficiently feed the
//// parser levels with token-appropriate data and constructs that are permitted
//// to cross lines (multi-line strings, array values) can pull additional lines
//// from the source.
////
//// The performance of this parser is acceptable up to 25% slower than `tom`
//// version 1 (initial benchmarks suggest it may be 25% faster).
////
//// [splitter]: https://splitter.hexdocs.pm/

import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import greenwood.{
  type Element, type Node, type Token, Bare, Node, NodeElement as N, Token,
  TokenElement as T, Trivia,
}
import molt/error.{type MoltError, ParseError}
import molt/internal/classifier
import molt/internal/parser/core.{
  type Splitters, type State, Building, NoTable, State,
}
import molt/internal/parser/scanners
import molt/internal/utils
import molt/types.{type TomlKind}
import splitter

// --- Public API ---

/// Parse TOML source into a Document CST node.
///
/// An up-front scan halts on any forbidden control character (per the TOML
/// spec: U+0000–U+0008, U+000B, U+000C, U+000E–U+001F, U+007F, and bare CR not
/// followed by LF) and is treated as corrupt input.
///
/// If there is a leading UTF-8 BOM, we keep it.
pub fn parse(source: String) -> Result(Node(TomlKind), MoltError) {
  let #(bom, source) = case source {
    "\u{FEFF}" <> rest -> #("\u{FEFF}", rest)
    _ -> #("", source)
  }

  use _ <- result.try(scan_control(source))

  core.new_state(bom)
  |> do_parse(source)
}

/// Single-pass control-char scan using a splitter (native fast scan).
/// On hit, computes the byte offset from the prefix length.
fn scan_control(source: String) -> Result(Nil, MoltError) {
  splitter.new([
    "\u{0000}", "\u{0001}", "\u{0002}", "\u{0003}", "\u{0004}", "\u{0005}",
    "\u{0006}", "\u{0007}", "\u{0008}", "\u{000B}", "\u{000C}", "\u{000E}",
    "\u{000F}", "\u{0010}", "\u{0011}", "\u{0012}", "\u{0013}", "\u{0014}",
    "\u{0015}", "\u{0016}", "\u{0017}", "\u{0018}", "\u{0019}", "\u{001A}",
    "\u{001B}", "\u{001C}", "\u{001D}", "\u{001E}", "\u{001F}", "\u{007F}",
    "\u{FEFF}", "\r",
  ])
  |> do_scan_control(input: source, offset: 0)
}

fn do_scan_control(
  controls controls: splitter.Splitter,
  input input: String,
  offset offset: Int,
) -> Result(Nil, MoltError) {
  let #(prefix, delim, input) = splitter.split(controls, input)
  let here = offset + string.byte_size(prefix)
  case delim {
    "" -> Ok(Nil)
    "\u{FEFF}" -> Error(ParseError("BOM not at start of file", here))
    "\u{0000}" -> Error(ParseError("Null byte in input", here))
    "\r" ->
      case input {
        "\n" <> more ->
          do_scan_control(controls:, input: more, offset: here + 2)
        _ -> Error(ParseError("Bare carriage return", here))
      }
    _ -> Error(ParseError("Forbidden control character", here))
  }
}

fn do_parse(state: State, input: String) -> Result(Node(TomlKind), MoltError) {
  use Nil <- result.try(state.error)

  case input {
    "" -> core.finalize(state)
    _ -> {
      let #(state, remaining) = process_line(state, input)
      do_parse(state, remaining)
    }
  }
}

fn process_line(state: State, input: String) -> #(State, String) {
  dispatch_line(state, splitter.split(state.sp.line, input))
}

fn dispatch_line(
  state: State,
  split_line: #(String, String, String),
) -> #(State, String) {
  let #(line, nl, rest) = split_line

  case core.peek_first_significant(line) {
    "" -> #(handle_blank_line(state:, line:, nl:), rest)
    "#" <> _ -> #(handle_comment_line(state:, line:, nl:), rest)
    "[[" <> _ -> #(
      handle_table_line(state:, kind: types.ArrayOfTables, line:, nl:),
      rest,
    )
    "[" <> _ -> #(
      handle_table_line(state:, kind: types.Table, line:, nl:),
      rest,
    )
    _ -> handle_kv_line(state:, line:, nl:, source_rest: rest)
  }
}

fn handle_blank_line(
  state state: State,
  line line: String,
  nl nl: String,
) -> State {
  let pending = case line {
    "" -> state.pending_trivia
    _ -> [greenwood.token(types.Whitespace, line), ..state.pending_trivia]
  }
  let pending = case nl {
    "" -> pending
    _ -> [greenwood.token(types.Newline, nl), ..pending]
  }
  State(..state, pending_trivia: pending)
}

fn handle_comment_line(
  state state: State,
  line line: String,
  nl nl: String,
) -> State {
  let #(pending, rest) = case core.take_ws(line) {
    #("", rest) -> #(state.pending_trivia, rest)
    #(ws, rest) -> #(
      [greenwood.token(types.Whitespace, ws), ..state.pending_trivia],
      rest,
    )
  }

  // rest starts with "#"; entire remainder of line is one comment token.
  let pending = [greenwood.token(types.Comment, rest), ..pending]
  let pending = case nl {
    "" -> pending
    _ -> [greenwood.token(types.Newline, nl), ..pending]
  }
  State(..state, pending_trivia: pending)
}

fn handle_table_line(
  state state: State,
  kind kind: TomlKind,
  line line: String,
  nl nl: String,
) -> State {
  // Flush any currently-open table.
  let doc_acc = core.flush_current_table(state)

  // Tokenize the header line (reverse-ordered).
  let header = scanners.tokenize_header_line(sp: state.sp, input: line, acc: [])
  let header = case nl {
    "" -> header
    _ -> [greenwood.token(types.Newline, nl), ..header]
  }
  // Split the header line's trailing comment off into trailing trivia.
  let #(children, trailing) =
    core.peel_trailing_comment_rev(list.map(header, T))

  // At the document head, route a blank-separated leading comment block to Root.
  let #(leading, state) = head_split(state)

  State(
    ..state,
    doc_acc:,
    current_table: Building(kind:, children:, trivia: leading, trailing:),
    pending_trivia: [],
  )
}

/// At the true document head (no statements yet, no open table), peel a
/// blank-separated leading comment block off the pending trivia and stash it as
/// Root's leading trivia, returning the trivia that stays on the first node. The
/// BOM is held separately (`state.bom`) and prepended to Root's leading trivia
/// at finalize, so it stays first regardless. Elsewhere this is a no-op.
fn head_split(state: State) -> #(List(Token(TomlKind)), State) {
  case state.current_table, state.doc_acc {
    NoTable, [] -> {
      let #(root_rev, node_rev) = core.peel_head_block(state.pending_trivia)
      #(node_rev, State(..state, root_leading: root_rev))
    }
    _, _ -> #(state.pending_trivia, state)
  }
}

/// Process a key-value line. The value may span multiple source lines (open
/// arrays, inline tables, or multi-line strings); when that happens the
/// scanners pull more lines from `source_rest` via the line splitter, emitting
/// the in-between newlines as content of the spanning construct.
///
/// `pending_nl` is the newline terminating the _current_ line. If the value
/// spans, it gets emitted as content; otherwise it becomes the KV's trailing
/// newline. Returns the updated state and the remaining unconsumed source.
fn handle_kv_line(
  state state: State,
  line line: String,
  nl nl: String,
  source_rest source_rest: String,
) -> #(State, String) {
  let #(children_rev, after_eq) =
    scanners.consume_key_and_eq(sp: state.sp, input: line, acc: [])
  let #(children_rev, final_nl, final_rest) =
    consume_value(
      sp: state.sp,
      input: after_eq,
      acc: children_rev,
      pending_nl: nl,
      source_rest:,
    )
  let children_rev = case final_nl {
    "" -> children_rev
    _ -> [T(Token(kind: types.Newline, text: final_nl)), ..children_rev]
  }
  let children_rev = wrap_dotted_key(children_rev)
  let full = greenwood.node(types.KeyValue, children_rev)
  // Validity is judged on the full line (a `key = # c` line is a KV with a
  // missing value, not unparsable junk). A valid KV carries its trailing
  // comment on `trivia.trailing`; an invalid line keeps the comment inline,
  // wrapped verbatim in an Error node, and takes only leading trivia.
  // At the document head, route a blank-separated leading comment block to Root.
  let #(leading, state) = head_split(state)
  let node = case is_valid_kv(full) {
    True -> {
      let #(clean_rev, trailing) = core.peel_trailing_comment_rev(children_rev)
      attach_line_trivia(
        node: greenwood.node(types.KeyValue, clean_rev),
        leading:,
        trailing:,
      )
    }
    False ->
      greenwood.node(types.Error, [N(full)])
      |> attach_pending_trivia(leading)
  }
  let state = State(..state, pending_trivia: [])
  #(add_kv(state, node), final_rest)
}

/// A KeyValue node is valid if it has an Equals token, a value after the
/// equals, and all BareKey tokens contain only valid bare key characters.
fn is_valid_kv(node: Node(TomlKind)) -> Bool {
  // node.children are in reverse order at this point
  let children = list.reverse(node.children)
  has_equals(children)
  && has_value_after_equals(children)
  && all_bare_keys_valid(children)
}

fn has_equals(children: List(Element(TomlKind))) -> Bool {
  list.any(children, fn(el) {
    case el {
      T(Token(kind: types.Equals, ..)) -> True
      _ -> False
    }
  })
}

fn has_value_after_equals(children: List(Element(TomlKind))) -> Bool {
  do_has_value_after_equals(children, False)
}

fn do_has_value_after_equals(
  children: List(Element(TomlKind)),
  past_equals: Bool,
) -> Bool {
  case children, past_equals {
    [], False -> True
    [], True -> False
    [T(Token(kind: types.Equals, ..)), ..rest], _ ->
      do_has_value_after_equals(rest, True)
    [T(Token(kind: types.Whitespace, ..)), ..rest], pe ->
      do_has_value_after_equals(rest, pe)
    [T(Token(kind: types.Newline, ..)), ..], True -> False
    [_, ..], True -> True
    [_, ..rest], False -> do_has_value_after_equals(rest, False)
  }
}

fn all_bare_keys_valid(children: List(Element(TomlKind))) -> Bool {
  list.all(children, fn(el) {
    case el {
      T(Token(kind: types.BareKey, text:)) -> utils.is_bare_key(text)
      N(node) if node.kind == types.Key -> all_bare_keys_valid(node.children)
      _ -> True
    }
  })
}

/// Consume the value portion of a KV line. Does not span lines itself:
/// only the constructs it dispatches into (arrays, inline tables, multi-line
/// strings) span. Returns the updated children, the pending newline (the one
/// terminating the line where the value ended), and the unconsumed source.
fn consume_value(
  sp sp: Splitters,
  input input: String,
  acc acc: List(Element(TomlKind)),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(List(Element(TomlKind)), String, String) {
  case input {
    "" -> #(acc, pending_nl, source_rest)
    _ -> {
      let #(prefix, delim, rest) = splitter.split(sp.value, input)
      let acc = emit_value_prefix(prefix, acc)
      case delim {
        "" -> #(acc, pending_nl, source_rest)
        " " | "\t" ->
          consume_value_after_whitespace(
            sp:,
            input: rest,
            acc:,
            pending_nl:,
            source_rest:,
            delim:,
          )
        "[" -> {
          let #(node, rem, rem_nl, rem_rest) =
            consume_array(sp:, input: rest, pending_nl:, source_rest:)
          consume_value(
            sp:,
            input: rem,
            acc: [N(node), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "{" -> {
          let #(node, rem, rem_nl, rem_rest) =
            consume_inline_table(sp:, input: rest, pending_nl:, source_rest:)
          consume_value(
            sp:,
            input: rem,
            acc: [N(node), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "\"" -> {
          let #(tok_, rem, rem_nl, rem_rest) =
            scanners.scan_basic_string(sp, rest, pending_nl, source_rest)
          consume_value(
            sp:,
            input: rem,
            acc: [T(tok_), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "'" -> {
          let #(tok_, rem, rem_nl, rem_rest) =
            scanners.scan_literal_string(
              sp:,
              input: rest,
              pending_nl:,
              source_rest:,
            )
          consume_value(
            sp:,
            input: rem,
            acc: [T(tok_), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "#" -> #(
          [T(Token(kind: types.Comment, text: "#" <> rest)), ..acc],
          pending_nl,
          source_rest,
        )
        "," ->
          consume_value(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.Comma, text: "")), ..acc],
            pending_nl:,
            source_rest:,
          )
        "]" ->
          consume_value(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.RightBracket, text: "")), ..acc],
            pending_nl:,
            source_rest:,
          )
        "}" ->
          consume_value(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.RightBrace, text: "")), ..acc],
            pending_nl:,
            source_rest:,
          )
        "=" ->
          consume_value(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.Equals, text: "")), ..acc],
            pending_nl:,
            source_rest:,
          )
        _ -> consume_value(sp:, input: rest, acc:, pending_nl:, source_rest:)
      }
    }
  }
}

fn emit_value_prefix(
  prefix: String,
  acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case prefix {
    "" -> acc
    _ -> [T(core.tokenize_value(prefix)), ..acc]
  }
}

/// If `acc` ends with a `LocalDate` token and the next value-splitter prefix
/// together with the date forms a valid `LocalDateTime` or `OffsetDateTime`,
/// fold the three pieces (date, single-space ws, time) into a single
/// datetime token. Otherwise return Error so the caller emits the ws
/// normally.
fn try_merge_datetime(
  acc acc: List(Element(TomlKind)),
  ws ws: String,
  rest rest: String,
  sp sp: Splitters,
) -> Result(#(List(Element(TomlKind)), String), Nil) {
  case ws, acc {
    " ", [T(Token(kind: types.LocalDate, text: date_text)), ..rest_acc] -> {
      let #(prefix, _delim, _r) = splitter.split(sp.value, rest)

      use <- bool.guard(prefix == "", return: Error(Nil))

      let combined = date_text <> " " <> prefix
      case classifier.match_datetime(combined) {
        Some(k) -> {
          let new_rest = string.drop_start(rest, string.length(prefix))
          Ok(#([T(Token(kind: k, text: combined)), ..rest_acc], new_rest))
        }
        None -> Error(Nil)
      }
    }
    _, _ -> Error(Nil)
  }
}

// --- Arrays (may span lines) ---

fn consume_array(
  sp sp: Splitters,
  input input: String,
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Node(TomlKind), String, String, String) {
  let #(children_rev, rem, rem_nl, rem_rest) =
    do_consume_array(
      sp:,
      input:,
      acc: [T(Token(kind: types.LeftBracket, text: ""))],
      pending_nl:,
      source_rest:,
    )
  let children_rev = group_array_elements(children_rev)
  let node = greenwood.node(types.Array, children_rev)
  #(node, rem, rem_nl, rem_rest)
}

/// Group flat array children (in reverse order) into ArrayElement nodes.
/// Each element gets leading trivia (comments/newlines/whitespace before value)
/// and contains the value + trailing comma/whitespace.
/// LeftBracket and RightBracket stay as direct children of the Array node.
fn group_array_elements(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  // Work in forward order, then reverse back
  list.reverse(children)
  |> do_group_array_forward(trivia_acc: [], element_acc: [], result: [])
}

/// Walk forward through array children, grouping into ArrayElement nodes.
/// - `trivia_acc`: accumulated trivia tokens (comments, newlines, whitespace)
///   that will become leading trivia on the next element
/// - `element_acc`: tokens belonging to the current element (value + trailing)
/// - `result`: completed elements/brackets in reverse order
fn do_group_array_forward(
  children children: List(Element(TomlKind)),
  trivia_acc trivia_acc: List(Token(TomlKind)),
  element_acc element_acc: List(Element(TomlKind)),
  result result: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> flush_element(trivia_acc:, element_acc:, result:)

    [T(Token(kind: types.LeftBracket, text: _)), ..rest] ->
      do_group_array_forward(children: rest, trivia_acc:, element_acc:, result: [
        T(Token(kind: types.LeftBracket, text: "")),
        ..result
      ])

    [T(Token(kind: types.RightBracket, text: _)), ..rest] -> {
      let result = flush_element(trivia_acc:, element_acc:, result:)
      do_group_array_forward(
        children: rest,
        trivia_acc: [],
        element_acc: [],
        result: [T(Token(kind: types.RightBracket, text: "")), ..result],
      )
    }

    [T(Token(kind: types.Comment, ..) as tok), ..rest] ->
      case element_acc {
        [] ->
          do_group_array_forward(
            children: rest,
            trivia_acc: [tok, ..trivia_acc],
            element_acc: [],
            result:,
          )
        _ ->
          do_group_array_forward(
            children: rest,
            trivia_acc:,
            element_acc: [T(tok), ..element_acc],
            result:,
          )
      }

    [T(Token(kind: types.Newline, ..) as tok), ..rest] ->
      case element_acc {
        [] ->
          do_group_array_forward(
            children: rest,
            trivia_acc: [tok, ..trivia_acc],
            element_acc: [],
            result:,
          )
        _ -> {
          let result =
            flush_element(
              trivia_acc:,
              element_acc: [T(tok), ..element_acc],
              result:,
            )
          do_group_array_forward(
            children: rest,
            trivia_acc: [],
            element_acc: [],
            result:,
          )
        }
      }

    [T(Token(kind: types.Whitespace, ..) as tok), ..rest] ->
      case element_acc {
        [] ->
          do_group_array_forward(
            children: rest,
            trivia_acc: [tok, ..trivia_acc],
            element_acc: [],
            result:,
          )
        _ ->
          do_group_array_forward(
            children: rest,
            trivia_acc:,
            element_acc: [T(tok), ..element_acc],
            result:,
          )
      }

    [T(Token(kind: types.Comma, ..) as tok), ..rest] -> {
      let element_acc = [T(tok), ..element_acc]
      // Everything on the same line after comma belongs to this element
      let #(element_acc, rest) = take_same_line(rest, element_acc)
      let result = flush_element(trivia_acc:, element_acc:, result:)
      do_group_array_forward(
        children: rest,
        trivia_acc: [],
        element_acc: [],
        result:,
      )
    }

    [el, ..rest] ->
      do_group_array_forward(
        children: rest,
        trivia_acc:,
        element_acc: [el, ..element_acc],
        result:,
      )
  }
}

/// Flush accumulated element tokens into an ArrayElement node with trivia.
fn flush_element(
  trivia_acc trivia_acc: List(Token(TomlKind)),
  element_acc element_acc: List(Element(TomlKind)),
  result result: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case element_acc {
    [] ->
      // No element to flush: put trivia back as bare tokens in correct order
      case trivia_acc {
        [] -> result
        _ ->
          list.fold(list.reverse(trivia_acc), result, fn(acc, tok) {
            [T(tok), ..acc]
          })
      }
    _ -> {
      // Leave children and trivia in reverse order: reverse_tree will fix them.
      // The element's trailing comment lives in trivia.trailing, like every
      // other line-terminated node.
      let #(children, trailing) = core.peel_trailing_comment_rev(element_acc)
      let trivia = case trivia_acc, trailing {
        [], [] -> Bare
        _, _ -> Trivia(leading: trivia_acc, trailing:)
      }
      let node = Node(kind: types.ArrayElement, children:, trivia:)
      [N(node), ..result]
    }
  }
}

/// Consume tokens on the same line (up to and including the newline).
/// Returns updated element_acc (reversed) and remaining children.
fn take_same_line(
  children: List(Element(TomlKind)),
  acc: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  case children {
    [] -> #(acc, [])
    [T(Token(kind: types.Newline, ..) as tok), ..rest] -> #(
      [T(tok), ..acc],
      rest,
    )
    [T(Token(kind: types.Whitespace, ..)) as el, ..rest] ->
      take_same_line(rest, [el, ..acc])
    [T(Token(kind: types.Comment, ..)) as el, ..rest] ->
      take_same_line(rest, [el, ..acc])
    _ -> #(acc, children)
  }
}

/// Group flat inline table children (in reverse order) into KeyValue nodes.
/// LeftBrace and RightBrace stay as direct children. Each key=value entry
/// between commas becomes a KeyValue node with leading trivia.
fn group_inline_table_entries(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  list.reverse(children)
  |> do_group_inline_forward(trivia_acc: [], entry_acc: [], result: [])
}

fn do_group_inline_forward(
  children children: List(Element(TomlKind)),
  trivia_acc trivia_acc: List(Token(TomlKind)),
  entry_acc entry_acc: List(Element(TomlKind)),
  result result: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> flush_inline_entry(trivia_acc:, entry_acc:, result:)

    [T(Token(kind: types.LeftBrace, ..)), ..rest] ->
      do_group_inline_forward(children: rest, trivia_acc:, entry_acc:, result: [
        T(Token(kind: types.LeftBrace, text: "")),
        ..result
      ])

    [T(Token(kind: types.RightBrace, ..)), ..rest] -> {
      let result = flush_inline_entry(trivia_acc:, entry_acc:, result:)
      do_group_inline_forward(
        children: rest,
        trivia_acc: [],
        entry_acc: [],
        result: [T(Token(kind: types.RightBrace, text: "")), ..result],
      )
    }

    [T(Token(kind: types.Comma, ..) as tok), ..rest] -> {
      // Comma belongs to current entry, then close it
      let entry_acc = [T(tok), ..entry_acc]
      let #(entry_acc, rest) = take_same_line(rest, entry_acc)
      let result = flush_inline_entry(trivia_acc:, entry_acc:, result:)
      do_group_inline_forward(
        children: rest,
        trivia_acc: [],
        entry_acc: [],
        result:,
      )
    }

    [T(Token(kind: types.Comment, ..) as tok), ..rest] ->
      case entry_acc {
        [] ->
          do_group_inline_forward(
            children: rest,
            trivia_acc: [tok, ..trivia_acc],
            entry_acc: [],
            result:,
          )
        _ ->
          do_group_inline_forward(
            children: rest,
            trivia_acc:,
            entry_acc: [T(tok), ..entry_acc],
            result:,
          )
      }

    [T(Token(kind: types.Newline, ..) as tok), ..rest] ->
      case entry_acc {
        [] ->
          do_group_inline_forward(
            children: rest,
            trivia_acc: [tok, ..trivia_acc],
            entry_acc: [],
            result:,
          )
        _ -> {
          let entry_acc = [T(tok), ..entry_acc]
          let result = flush_inline_entry(trivia_acc:, entry_acc:, result:)
          do_group_inline_forward(
            children: rest,
            trivia_acc: [],
            entry_acc: [],
            result:,
          )
        }
      }

    [T(Token(kind: types.Whitespace, ..) as tok), ..rest] ->
      case entry_acc {
        [] ->
          do_group_inline_forward(
            children: rest,
            trivia_acc: [tok, ..trivia_acc],
            entry_acc: [],
            result:,
          )
        _ ->
          do_group_inline_forward(
            children: rest,
            trivia_acc:,
            entry_acc: [T(tok), ..entry_acc],
            result:,
          )
      }

    [el, ..rest] ->
      do_group_inline_forward(
        children: rest,
        trivia_acc:,
        entry_acc: [el, ..entry_acc],
        result:,
      )
  }
}

fn flush_inline_entry(
  trivia_acc trivia_acc: List(Token(TomlKind)),
  entry_acc entry_acc: List(Element(TomlKind)),
  result result: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case entry_acc {
    [] ->
      case trivia_acc {
        [] -> result
        _ ->
          list.fold(list.reverse(trivia_acc), result, fn(acc, tok) {
            [T(tok), ..acc]
          })
      }
    _ -> {
      let #(children, trailing) = core.peel_trailing_comment_rev(entry_acc)
      let trivia = case trivia_acc, trailing {
        [], [] -> Bare
        _, _ -> Trivia(leading: trivia_acc, trailing:)
      }
      let node = Node(kind: types.KeyValue, children:, trivia:)
      [N(node), ..result]
    }
  }
}

fn do_consume_array(
  sp sp: Splitters,
  input input: String,
  acc acc: List(Element(TomlKind)),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(List(Element(TomlKind)), String, String, String) {
  case input {
    "" -> pull_next_line_array(sp:, acc:, pending_nl:, source_rest:)
    _ -> {
      let #(prefix, delim, rest) = splitter.split(sp.value, input)
      let acc = emit_value_prefix(prefix, acc)
      case delim {
        "" -> pull_next_line_array(sp:, acc:, pending_nl:, source_rest:)
        "]" -> #(
          [T(Token(kind: types.RightBracket, text: "")), ..acc],
          rest,
          pending_nl,
          source_rest,
        )
        "," ->
          do_consume_array(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.Comma, text: "")), ..acc],
            pending_nl:,
            source_rest:,
          )
        " " | "\t" ->
          consume_array_after_whitespace(
            sp:,
            input: rest,
            acc:,
            pending_nl:,
            source_rest:,
            delim:,
          )
        "[" -> {
          let #(nested, rem, rem_nl, rem_rest) =
            consume_array(sp:, input: rest, pending_nl:, source_rest:)
          do_consume_array(
            sp:,
            input: rem,
            acc: [N(nested), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "{" -> {
          let #(nested, rem, rem_nl, rem_rest) =
            consume_inline_table(sp:, input: rest, pending_nl:, source_rest:)
          do_consume_array(
            sp:,
            input: rem,
            acc: [N(nested), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "\"" -> {
          let #(tok_, rem, rem_nl, rem_rest) =
            scanners.scan_basic_string(sp, rest, pending_nl, source_rest)
          do_consume_array(
            sp:,
            input: rem,
            acc: [T(tok_), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "'" -> {
          let #(tok_, rem, rem_nl, rem_rest) =
            scanners.scan_literal_string(
              sp:,
              input: rest,
              pending_nl:,
              source_rest:,
            )
          do_consume_array(
            sp:,
            input: rem,
            acc: [T(tok_), ..acc],
            pending_nl: rem_nl,
            source_rest: rem_rest,
          )
        }
        "#" -> {
          // Comment extends to end of current line. Emit it, then continue
          // by pulling the next line (still inside the array).
          let acc = [T(Token(kind: types.Comment, text: "#" <> rest)), ..acc]
          pull_next_line_array(sp:, acc:, pending_nl:, source_rest:)
        }
        "=" ->
          do_consume_array(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.InvalidValue, text: "=")), ..acc],
            pending_nl:,
            source_rest:,
          )
        _ -> do_consume_array(sp:, input: rest, acc:, pending_nl:, source_rest:)
      }
    }
  }
}

fn consume_value_after_whitespace(
  sp sp: Splitters,
  input input: String,
  acc acc: List(Element(TomlKind)),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
  delim delim: String,
) -> #(List(Element(TomlKind)), String, String) {
  {
    let #(ws, rest) = core.scan_ws(delim, input)
    case try_merge_datetime(acc:, ws:, rest: rest, sp:) {
      Ok(#(merged_acc, new_rest)) ->
        consume_value(
          sp:,
          input: new_rest,
          acc: merged_acc,
          pending_nl:,
          source_rest:,
        )
      Error(Nil) ->
        consume_value(
          sp:,
          input: rest,
          acc: [T(Token(kind: types.Whitespace, text: ws)), ..acc],
          pending_nl:,
          source_rest:,
        )
    }
  }
}

fn consume_array_after_whitespace(
  sp sp: Splitters,
  input input: String,
  acc acc: List(Element(TomlKind)),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
  delim delim: String,
) -> #(List(Element(TomlKind)), String, String, String) {
  let #(ws, rest) = core.scan_ws(delim, input)
  case try_merge_datetime(acc:, ws:, rest:, sp:) {
    Ok(#(merged_acc, rest)) ->
      do_consume_array(
        sp:,
        input: rest,
        acc: merged_acc,
        pending_nl:,
        source_rest:,
      )
    Error(Nil) ->
      do_consume_array(
        sp:,
        input: rest,
        acc: [T(Token(kind: types.Whitespace, text: ws)), ..acc],
        pending_nl:,
        source_rest:,
      )
  }
}

/// Inside an open `[ ... ]`: emit the pending newline as content, pull the
/// next source line, and resume scanning. If the source is exhausted the
/// array is unterminated: we surface what we have rather than loop forever.
fn pull_next_line_array(
  sp sp: Splitters,
  acc acc: List(Element(TomlKind)),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(List(Element(TomlKind)), String, String, String) {
  let acc = case pending_nl {
    "" -> acc
    _ -> [T(Token(kind: types.Newline, text: pending_nl)), ..acc]
  }
  case source_rest {
    "" -> #(acc, "", "", "")
    _ -> {
      let #(next_line, next_nl, more_rest) =
        splitter.split(sp.line, source_rest)
      do_consume_array(
        sp:,
        input: next_line,
        acc:,
        pending_nl: next_nl,
        source_rest: more_rest,
      )
    }
  }
}

// --- Inline tables (may span lines; TOML 1.1) ---

fn consume_inline_table(
  sp sp: Splitters,
  input input: String,
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Node(TomlKind), String, String, String) {
  let #(children_rev, rem, rem_nl, rem_rest) =
    do_consume_inline_table(
      sp:,
      input:,
      acc: [T(Token(kind: types.LeftBrace, text: ""))],
      pending_nl:,
      source_rest:,
      after_eq: False,
    )
  let children_rev = group_inline_table_entries(children_rev)
  let node = greenwood.node(types.InlineTable, children_rev)
  #(node, rem, rem_nl, rem_rest)
}

/// `after_eq` distinguishes key position (False) from value position (True).
/// In key position, prefixes are emitted as BareKey. In value position they
/// are classified by `tokenize_value` so unquoted barewords surface as
/// `types.InvalidValue` for the validator to reject.
fn do_consume_inline_table(
  sp sp: Splitters,
  input input: String,
  acc acc: List(Element(TomlKind)),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
  after_eq after_eq: Bool,
) -> #(List(Element(TomlKind)), String, String, String) {
  case input {
    "" ->
      pull_next_line_inline_table(
        sp:,
        acc:,
        pending_nl:,
        source_rest:,
        after_eq:,
      )
    _ -> {
      let #(prefix, delim, rest) = splitter.split(sp.value, input)
      let acc = case prefix, after_eq {
        "", _ -> acc
        _, True -> [T(core.tokenize_value(prefix)), ..acc]
        _, False -> [T(Token(kind: types.BareKey, text: prefix)), ..acc]
      }
      case delim {
        "" ->
          pull_next_line_inline_table(
            sp:,
            acc:,
            pending_nl:,
            source_rest:,
            after_eq:,
          )
        "}" -> #(
          [T(Token(kind: types.RightBrace, text: "")), ..acc],
          rest,
          pending_nl,
          source_rest,
        )
        "," ->
          do_consume_inline_table(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.Comma, text: "")), ..acc],
            pending_nl:,
            source_rest:,
            after_eq: False,
          )
        " " | "\t" -> {
          let #(ws, rest_after) = core.scan_ws(delim, rest)
          do_consume_inline_table(
            sp:,
            input: rest_after,
            acc: [T(Token(kind: types.Whitespace, text: ws)), ..acc],
            pending_nl:,
            source_rest:,
            after_eq:,
          )
        }
        "=" ->
          do_consume_inline_table(
            sp:,
            input: rest,
            acc: [T(Token(kind: types.Equals, text: "")), ..acc],
            pending_nl:,
            source_rest:,
            after_eq: True,
          )
        "[" -> {
          let #(nested, input, pending_nl, source_rest) =
            consume_array(sp:, input: rest, pending_nl:, source_rest:)
          do_consume_inline_table(
            sp:,
            input:,
            acc: [N(nested), ..acc],
            pending_nl:,
            source_rest:,
            after_eq:,
          )
        }
        "{" -> {
          let #(nested, input, pending_nl, source_rest) =
            consume_inline_table(sp:, input: rest, pending_nl:, source_rest:)
          do_consume_inline_table(
            sp:,
            input:,
            acc: [N(nested), ..acc],
            pending_nl:,
            source_rest:,
            after_eq:,
          )
        }
        "\"" -> {
          let #(tok_, input, pending_nl, source_rest) =
            scanners.scan_basic_string(sp, rest, pending_nl, source_rest)
          do_consume_inline_table(
            sp:,
            input:,
            acc: [T(tok_), ..acc],
            pending_nl:,
            source_rest:,
            after_eq:,
          )
        }
        "'" -> {
          let #(tok_, input, pending_nl, source_rest) =
            scanners.scan_literal_string(
              sp:,
              input: rest,
              pending_nl:,
              source_rest:,
            )
          do_consume_inline_table(
            sp:,
            input:,
            acc: [T(tok_), ..acc],
            pending_nl:,
            source_rest:,
            after_eq:,
          )
        }
        "#" -> {
          let acc = [T(Token(kind: types.Comment, text: "#" <> rest)), ..acc]
          pull_next_line_inline_table(
            sp:,
            acc:,
            pending_nl:,
            source_rest:,
            after_eq:,
          )
        }
        _ ->
          do_consume_inline_table(
            sp:,
            input: rest,
            acc:,
            pending_nl:,
            source_rest:,
            after_eq:,
          )
      }
    }
  }
}

fn pull_next_line_inline_table(
  sp sp: Splitters,
  acc acc: List(Element(TomlKind)),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
  after_eq after_eq: Bool,
) -> #(List(Element(TomlKind)), String, String, String) {
  let acc = case pending_nl {
    "" -> acc
    _ -> [T(Token(kind: types.Newline, text: pending_nl)), ..acc]
  }
  case source_rest {
    "" -> #(acc, "", "", "")
    _ -> {
      let #(next_line, pending_nl, source_rest) =
        splitter.split(sp.line, source_rest)
      do_consume_inline_table(
        sp:,
        input: next_line,
        acc:,
        pending_nl:,
        source_rest:,
        after_eq:,
      )
    }
  }
}

// --- String scanners ---

/// If the key tokens contain a Dot, wrap the contiguous key tokens in a Key
/// node. Operates on reverse-ordered children, returns reverse-ordered
/// children.
///
/// Structure of `children_rev` for `[leading_ws] key_tokens [ws] = ws value`:
/// head→tail = [..value.., Equals, ws_before_eq, key_tokens.., leading_ws].
/// The Key node only encloses the key_tokens segment. Whitespace flanking it
/// (leading line ws, ws between key and `=`) stays inline as siblings.
///
/// All list segments below preserve the original head-to-tail (reverse-of-
/// forward) order of `children_rev`, so the final flatten yields a valid
/// reverse-ordered children list that `reverse_tree` flips to forward order.
fn wrap_dotted_key(
  children_rev: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  let #(after_eq_rev, eq_and_key_rev) = split_at_equals_rev(children_rev, [])
  case eq_and_key_rev {
    [] -> children_rev
    [eq_el, ..key_rev] ->
      case has_dot_token(key_rev) {
        False -> children_rev
        True -> {
          let #(trailing_ws_rev, after_ws_rev) = take_trivia_prefix(key_rev, [])
          let #(key_inner_rev, leading_rev) = take_key_tokens(after_ws_rev, [])
          let key_node = greenwood.node(types.Key, key_inner_rev)
          list.flatten([
            after_eq_rev,
            [eq_el],
            trailing_ws_rev,
            [N(key_node)],
            leading_rev,
          ])
        }
      }
  }
}

fn split_at_equals_rev(
  children_rev: List(Element(TomlKind)),
  acc: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  case children_rev {
    [] -> #(list.reverse(acc), [])
    [T(Token(kind: types.Equals, ..)), ..] as tail -> #(list.reverse(acc), tail)
    [el, ..rest] -> split_at_equals_rev(rest, [el, ..acc])
  }
}

fn has_dot_token(children: List(Element(TomlKind))) -> Bool {
  list.any(children, fn(el) {
    case el {
      T(Token(kind: types.Dot, ..)) -> True
      _ -> False
    }
  })
}

/// Take whitespace tokens off the head of a list (in head order). Returns the
/// taken prefix in its original head order, and the unconsumed tail.
fn take_trivia_prefix(
  items: List(Element(TomlKind)),
  acc: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  case items {
    [T(Token(kind: types.Whitespace, ..)) as el, ..rest] ->
      take_trivia_prefix(rest, [el, ..acc])
    _ -> #(list.reverse(acc), items)
  }
}

/// Take the contiguous key-run from the head of a list (in head order).
/// A key-run is `BareKey | Dot | BasicString | LiteralString | Whitespace`:
/// TOML allows whitespace around dots (`a . b` is the same as `a.b`),
/// so interior whitespace belongs inside the Key node.
///
/// After greedy collection, strip any trailing whitespace (in walk order,
/// i.e., the most recently taken items). That trailing run corresponds to
/// leading line whitespace in forward order, which is _not_ part of the key.
fn take_key_tokens(
  items: List(Element(TomlKind)),
  acc: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  case items {
    [T(Token(kind: types.BareKey, ..)) as el, ..rest]
    | [T(Token(kind: types.Dot, ..)) as el, ..rest]
    | [T(Token(kind: types.BasicString, ..)) as el, ..rest]
    | [T(Token(kind: types.LiteralString, ..)) as el, ..rest]
    | [T(Token(kind: types.Whitespace, ..)) as el, ..rest] ->
      take_key_tokens(rest, [el, ..acc])
    _ -> {
      let #(stripped_acc, ws_tail) = peel_leading_ws_from_acc(acc, [])
      #(list.reverse(stripped_acc), list.append(ws_tail, items))
    }
  }
}

/// Pop whitespace tokens off the head of `acc` (i.e., the most recently
/// taken items, which sit at the tail of the key-run in walk order).
/// Returns the trimmed acc and the popped whitespace in walk order
/// (which is `acc`-head order).
fn peel_leading_ws_from_acc(
  acc: List(Element(TomlKind)),
  ws_acc: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  case acc {
    [T(Token(kind: types.Whitespace, ..)) as el, ..rest] ->
      peel_leading_ws_from_acc(rest, [el, ..ws_acc])
    _ -> #(acc, list.reverse(ws_acc))
  }
}

// --- Table management ---

fn add_kv(state: State, kv_node: Node(TomlKind)) -> State {
  case state.current_table {
    NoTable -> State(..state, doc_acc: [N(kv_node), ..state.doc_acc])
    Building(kind: k, children: c, trivia: t, trailing: tr) ->
      State(
        ..state,
        current_table: Building(
          kind: k,
          children: [N(kv_node), ..c],
          trivia: t,
          trailing: tr,
        ),
      )
  }
}

/// Attach leading (reverse-ordered pending) and trailing (reverse-ordered)
/// trivia to a node, leaving it `Bare` when both are empty.
fn attach_line_trivia(
  node node: Node(TomlKind),
  leading leading: List(Token(TomlKind)),
  trailing trailing: List(Token(TomlKind)),
) -> Node(TomlKind) {
  case leading, trailing {
    [], [] -> node
    _, _ -> Node(..node, trivia: Trivia(leading:, trailing:))
  }
}

fn attach_pending_trivia(
  node: Node(TomlKind),
  pending_rev: List(Token(TomlKind)),
) -> Node(TomlKind) {
  case pending_rev {
    [] -> node
    _ -> Node(..node, trivia: Trivia(leading: pending_rev, trailing: []))
  }
}
// --- Finalization ---
