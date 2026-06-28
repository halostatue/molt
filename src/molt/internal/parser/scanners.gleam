import casefold
import gleam/bool
import gleam/int
import gleam/result
import gleam/string
import greenwood.{type Element, type Token, Token, TokenElement as T}
import molt/internal/parser/core.{type Splitters}
import molt/internal/utils
import molt/types.{type TomlKind}
import splitter

/// Scan a basic string starting just after the opening `"`. If the input
/// immediately continues with `""`, this is the opening of a triple-quoted
/// multi-line string and we switch into that mode (which may pull more lines
/// from `source_rest`). Otherwise it's a single-line string, which cannot
/// cross a newline.
pub fn scan_basic_string(
  sp sp: Splitters,
  input input: String,
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Token(TomlKind), String, String, String) {
  case input {
    "\"\"" <> after_triple -> {
      let kind = case after_triple {
        "" -> types.MultilineBasicStringNl
        _ -> types.MultilineBasicString
      }
      scan_multiline_basic(
        sp:,
        kind:,
        input: after_triple,
        pending_nl:,
        source_rest:,
      )
    }
    _ ->
      case do_scan_basic(split: sp.basic_str, input:, acc: []) {
        Ok(#(parts_rev, rest)) -> {
          #(
            greenwood.token(types.BasicString, utils.reverse_concat(parts_rev)),
            rest,
            pending_nl,
            source_rest,
          )
        }
        Error(UnterminatedBasic) -> #(
          greenwood.token(types.InvalidBasicString, "\"" <> input),
          "",
          pending_nl,
          source_rest,
        )
        Error(BadEscape) -> #(
          greenwood.token(types.InvalidValue, "\"" <> input),
          "",
          pending_nl,
          source_rest,
        )
      }
  }
}

/// Scan a literal string starting just after the opening `'`. Like
/// `scan_basic_string`, switches to multi-line mode on `''`.
pub fn scan_literal_string(
  sp sp: Splitters,
  input input: String,
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Token(TomlKind), String, String, String) {
  case input {
    "''" <> after_triple -> {
      let kind = case after_triple {
        "" -> types.MultilineLiteralStringNl
        _ -> types.MultilineLiteralString
      }
      scan_multiline_literal(
        sp:,
        kind:,
        input: after_triple,
        pending_nl:,
        source_rest:,
      )
    }
    _ -> {
      let #(prefix, delim, rest) = splitter.split(sp.literal_str, input)
      case delim {
        "'" -> #(
          greenwood.token(types.LiteralString, prefix),
          rest,
          pending_nl,
          source_rest,
        )
        _ -> #(
          greenwood.token(types.InvalidLiteralString, "'" <> input),
          "",
          pending_nl,
          source_rest,
        )
      }
    }
  }
}

/// Scan a multi-line basic string. `input` is the source just past the
/// opening `"""`. Walks the current line, pulls more from `source_rest`
/// when needed, and stops after the closing `"""` (with trailing-quote
/// absorption).
fn scan_multiline_basic(
  sp sp: Splitters,
  kind kind: TomlKind,
  input input: String,
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Token(TomlKind), String, String, String) {
  case kind {
    types.MultilineBasicStringNl -> {
      // The leading newline is encoded in the kind; discard pending_nl and pull
      // the first content line so it is never stored in the token text.
      let #(input, pending_nl, source_rest) =
        splitter.split(sp.line, source_rest)
      scan_ml_basic(
        sp:,
        kind:,
        input:,
        parts_rev: [],
        pending_nl:,
        source_rest:,
      )
    }
    _ ->
      scan_ml_basic(
        sp:,
        kind:,
        input:,
        parts_rev: [],
        pending_nl:,
        source_rest:,
      )
  }
}

fn absorb_trailing_basic(
  parts_rev: List(String),
  rest: String,
) -> #(List(String), String) {
  case rest {
    "\"\"" <> after ->
      case string.starts_with(after, "\"") {
        True -> #(parts_rev, rest)
        False -> #(["\"\"", ..parts_rev], after)
      }
    "\"" <> after ->
      case string.starts_with(after, "\"") {
        True -> #(parts_rev, rest)
        False -> #(["\"", ..parts_rev], after)
      }
    _ -> #(parts_rev, rest)
  }
}

/// Single-line basic-string escape parser. Pattern-matches the byte after
/// `\` directly (no `pop_grapheme`) and returns the full escape fragment
/// (including the leading `\`) plus the remaining input. Returns `Error`
/// when the escape isn't a valid TOML escape: the caller turns that into
/// an `InvalidValue` token.
///
/// Per spec (1.0 + 1.1): valid escapes are `\"`, `\\`, `\b`, `\t`, `\n`,
/// `\f`, `\r`, `\e` (1.1), `\uXXXX`, `\UXXXXXXXX`, and `\xXX` (1.1).
/// Unicode escapes must produce a valid Unicode scalar (≤ U+10FFFF, not a
/// surrogate U+D800–U+DFFF). Single-line strings have no line-ending escape.
fn scan_basic_escape(input: String) -> Result(#(String, String), Nil) {
  case input {
    "\"" <> input -> Ok(#("\\\"", input))
    "\\" <> input -> Ok(#("\\\\", input))
    "b" <> input -> Ok(#("\\b", input))
    "t" <> input -> Ok(#("\\t", input))
    "n" <> input -> Ok(#("\\n", input))
    "f" <> input -> Ok(#("\\f", input))
    "r" <> input -> Ok(#("\\r", input))
    "e" <> input -> Ok(#("\\e", input))
    "u" <> input -> {
      use #(hex, input) <- result.try(take_n_hex(input:, n: 4, acc: []))
      use _ <- result.try(parse_valid_scalar(hex))
      Ok(#("\\u" <> hex, input))
    }
    "U" <> input -> {
      use #(hex, input) <- result.try(take_n_hex(input:, n: 8, acc: []))
      use _ <- result.try(parse_valid_scalar(hex))
      Ok(#("\\U" <> hex, input))
    }
    "x" <> input -> {
      use #(hex, input) <- result.try(take_n_hex(input:, n: 2, acc: []))
      Ok(#("\\x" <> hex, input))
    }
    _ -> Error(Nil)
  }
}

/// Take exactly `n` hex digits from the front of `input`, accumulating into
/// `acc`. Pattern-matches single chars (no `pop_grapheme`); rejects when
/// the next byte isn't a hex digit or the input is too short.
fn take_n_hex(
  input input: String,
  n n: Int,
  acc acc: List(String),
) -> Result(#(String, String), Nil) {
  case n {
    0 -> Ok(#(utils.reverse_concat(acc), input))
    _ ->
      case input {
        "0" <> input -> take_n_hex(input:, n: n - 1, acc: ["0", ..acc])
        "1" <> input -> take_n_hex(input:, n: n - 1, acc: ["1", ..acc])
        "2" <> input -> take_n_hex(input:, n: n - 1, acc: ["2", ..acc])
        "3" <> input -> take_n_hex(input:, n: n - 1, acc: ["3", ..acc])
        "4" <> input -> take_n_hex(input:, n: n - 1, acc: ["4", ..acc])
        "5" <> input -> take_n_hex(input:, n: n - 1, acc: ["5", ..acc])
        "6" <> input -> take_n_hex(input:, n: n - 1, acc: ["6", ..acc])
        "7" <> input -> take_n_hex(input:, n: n - 1, acc: ["7", ..acc])
        "8" <> input -> take_n_hex(input:, n: n - 1, acc: ["8", ..acc])
        "9" <> input -> take_n_hex(input:, n: n - 1, acc: ["9", ..acc])
        "a" <> input -> take_n_hex(input:, n: n - 1, acc: ["a", ..acc])
        "b" <> input -> take_n_hex(input:, n: n - 1, acc: ["b", ..acc])
        "c" <> input -> take_n_hex(input:, n: n - 1, acc: ["c", ..acc])
        "d" <> input -> take_n_hex(input:, n: n - 1, acc: ["d", ..acc])
        "e" <> input -> take_n_hex(input:, n: n - 1, acc: ["e", ..acc])
        "f" <> input -> take_n_hex(input:, n: n - 1, acc: ["f", ..acc])
        "A" <> input -> take_n_hex(input:, n: n - 1, acc: ["A", ..acc])
        "B" <> input -> take_n_hex(input:, n: n - 1, acc: ["B", ..acc])
        "C" <> input -> take_n_hex(input:, n: n - 1, acc: ["C", ..acc])
        "D" <> input -> take_n_hex(input:, n: n - 1, acc: ["D", ..acc])
        "E" <> input -> take_n_hex(input:, n: n - 1, acc: ["E", ..acc])
        "F" <> input -> take_n_hex(input:, n: n - 1, acc: ["F", ..acc])
        _ -> Error(Nil)
      }
  }
}

/// Parse a hex string as an integer and verify it's a valid Unicode scalar:
/// ≤ U+10FFFF and not in the surrogate range U+D800–U+DFFF.
fn parse_valid_scalar(hex: String) -> Result(Int, Nil) {
  case int.base_parse(hex, 16) {
    Ok(cp) if cp >= 0 && cp <= 0x10FFFF && { cp < 0xD800 || cp > 0xDFFF } ->
      Ok(cp)
    _ -> Error(Nil)
  }
}

type BasicScanError {
  /// Hit end-of-line without a closing `"`.
  UnterminatedBasic
  /// Found a `\` with no valid escape sequence following it.
  BadEscape
}

fn do_scan_basic(
  split split: splitter.Splitter,
  input input: String,
  acc acc: List(String),
) -> Result(#(List(String), String), BasicScanError) {
  let #(prefix, delim, rest) = splitter.split(split, input)
  let acc = [prefix, ..acc]
  case delim {
    "" -> Error(UnterminatedBasic)
    "\"" -> Ok(#(acc, rest))
    "\\" ->
      case scan_basic_escape(rest) {
        Ok(#(fragment, input)) ->
          do_scan_basic(split:, input:, acc: [fragment, ..acc])
        Error(Nil) -> Error(BadEscape)
      }
    _ -> Error(UnterminatedBasic)
  }
}

fn scan_ml_basic(
  sp sp: Splitters,
  kind kind: TomlKind,
  input input: String,
  parts_rev parts_rev: List(String),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Token(TomlKind), String, String, String) {
  // Unterminated multi-line string.
  use <- bool.guard(input == "" && source_rest == "", return: #(
    Token(types.InvalidMultilineBasicString, utils.reverse_concat(parts_rev)),
    "",
    "",
    "",
  ))

  // End of the current line: emit the pending newline and pull the next line.
  use <- bool.lazy_guard(input == "", return: fn() {
    let parts_rev = maybe_emit_next_part(pending_nl, parts_rev)
    let #(input, pending_nl, source_rest) = splitter.split(sp.line, source_rest)
    scan_ml_basic(sp:, kind:, input:, parts_rev:, pending_nl:, source_rest:)
  })

  let #(prefix, delim, input) = splitter.split(sp.ml_basic, input)
  let parts_rev = maybe_emit_next_part(prefix, parts_rev)

  use <- bool.lazy_guard(delim == "", return: fn() {
    scan_ml_basic(sp:, kind:, input: "", parts_rev:, pending_nl:, source_rest:)
  })

  use <- bool.lazy_guard(delim == "\"\"\"", return: fn() {
    let #(parts_rev, input) = absorb_trailing_basic(parts_rev, input)
    #(
      greenwood.token(kind, utils.reverse_concat(parts_rev)),
      input,
      pending_nl,
      source_rest,
    )
  })

  use <- bool.lazy_guard(delim != "\\", return: fn() {
    scan_ml_basic(sp:, kind:, input:, parts_rev:, pending_nl:, source_rest:)
  })

  case scan_basic_escape(input) {
    Ok(#(fragment, input)) ->
      scan_ml_basic(
        sp:,
        kind:,
        input:,
        parts_rev: [fragment, ..parts_rev],
        pending_nl:,
        source_rest:,
      )
    Error(Nil) -> {
      // Not a named/unicode/byte escape. In multiline mode, `\` followed by
      // zero or more spaces/tabs at end of line is a line-ending escape: push
      // the `\` and the trailing whitespace as one fragment and continue (the
      // next-line pull will add the nl). Otherwise it's a bad escape.
      let parts_rev = ["\\" <> input, ..parts_rev]

      use <- bool.guard(!casefold.is_blank(input), return: #(
        Token(types.InvalidValue, utils.reverse_concat(parts_rev)),
        "",
        "",
        "",
      ))

      scan_ml_basic(
        sp:,
        kind:,
        input: "",
        parts_rev:,
        pending_nl:,
        source_rest:,
      )
    }
  }
}

fn do_scan_ml_literal(
  sp sp: Splitters,
  kind kind: TomlKind,
  input input: String,
  parts_rev parts_rev: List(String),
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Token(TomlKind), String, String, String) {
  use <- bool.guard(input == "" && source_rest == "", return: #(
    Token(types.InvalidMultilineLiteralString, utils.reverse_concat(parts_rev)),
    "",
    "",
    "",
  ))

  use <- bool.lazy_guard(input == "", return: fn() {
    let parts_rev = maybe_emit_next_part(pending_nl, parts_rev)
    let #(input, pending_nl, source_rest) = splitter.split(sp.line, source_rest)
    do_scan_ml_literal(
      sp:,
      kind:,
      input:,
      parts_rev:,
      pending_nl:,
      source_rest:,
    )
  })

  let #(prefix, delim, input) = splitter.split(sp.ml_literal, input)
  let parts_rev = maybe_emit_next_part(prefix, parts_rev)

  use <- bool.guard(delim == "'''", return: {
    let #(parts_rev, input) = absorb_trailing_literal(parts_rev, input)
    #(
      greenwood.token(kind, utils.reverse_concat(parts_rev)),
      input,
      pending_nl,
      source_rest,
    )
  })

  use <- bool.lazy_guard(delim == "", return: fn() {
    do_scan_ml_literal(
      sp:,
      kind:,
      input: "",
      parts_rev:,
      pending_nl:,
      source_rest:,
    )
  })

  do_scan_ml_literal(sp:, kind:, input:, parts_rev:, pending_nl:, source_rest:)
}

fn absorb_trailing_literal(
  parts_rev: List(String),
  rest: String,
) -> #(List(String), String) {
  case rest {
    "''" <> after ->
      case string.starts_with(after, "'") {
        True -> #(parts_rev, rest)
        False -> #(["''", ..parts_rev], after)
      }
    "'" <> after ->
      case string.starts_with(after, "'") {
        True -> #(parts_rev, rest)
        False -> #(["'", ..parts_rev], after)
      }
    _ -> #(parts_rev, rest)
  }
}

/// Scan a multi-line literal string. `input` is the source just past the
/// opening `'''`.
fn scan_multiline_literal(
  sp sp: Splitters,
  kind kind: TomlKind,
  input input: String,
  pending_nl pending_nl: String,
  source_rest source_rest: String,
) -> #(Token(TomlKind), String, String, String) {
  case kind {
    types.MultilineLiteralStringNl -> {
      // The leading newline is encoded in the kind; discard pending_nl and pull
      // the first content line so it is never stored in the token text.
      let #(input, pending_nl, source_rest) =
        splitter.split(sp.line, source_rest)
      do_scan_ml_literal(
        sp:,
        kind:,
        input:,
        parts_rev: [],
        pending_nl:,
        source_rest:,
      )
    }
    _ ->
      do_scan_ml_literal(
        sp:,
        kind:,
        input:,
        parts_rev: [],
        pending_nl:,
        source_rest:,
      )
  }
}

pub fn tokenize_header_line(
  sp sp: Splitters,
  input input: String,
  acc acc: List(Token(TomlKind)),
) -> List(Token(TomlKind)) {
  case input {
    "" -> acc
    _ -> {
      let #(prefix, delim, rest) = splitter.split(sp.key, input)
      let acc = case prefix {
        "" -> acc
        _ -> [greenwood.token(types.BareKey, prefix), ..acc]
      }
      case delim {
        "" -> acc
        "[" ->
          tokenize_header_line(sp:, input: rest, acc: [
            greenwood.token(types.LeftBracket, ""),
            ..acc
          ])
        "]" ->
          tokenize_header_line(sp:, input: rest, acc: [
            greenwood.token(types.RightBracket, ""),
            ..acc
          ])
        "." ->
          tokenize_header_line(sp:, input: rest, acc: [
            greenwood.token(types.Dot, ""),
            ..acc
          ])
        "=" ->
          tokenize_header_line(sp:, input: rest, acc: [
            greenwood.token(types.Equals, ""),
            ..acc
          ])
        " " | "\t" -> {
          let #(ws, rest_after) = core.scan_ws(delim, rest)
          tokenize_header_line(sp:, input: rest_after, acc: [
            greenwood.token(types.Whitespace, ws),
            ..acc
          ])
        }
        "\"" -> {
          let #(str_tok, rest_after, _, _) =
            scan_basic_string(sp:, input: rest, pending_nl: "", source_rest: "")
          tokenize_header_line(sp:, input: rest_after, acc: [str_tok, ..acc])
        }
        "'" -> {
          let #(str_tok, rest_after, _, _) =
            scan_literal_string(
              sp:,
              input: rest,
              pending_nl: "",
              source_rest: "",
            )
          tokenize_header_line(sp:, input: rest_after, acc: [str_tok, ..acc])
        }
        "#" -> [greenwood.token(types.Comment, "#" <> rest), ..acc]
        _ -> tokenize_header_line(sp:, input: rest, acc:)
      }
    }
  }
}

pub fn consume_key_and_eq(
  sp sp: Splitters,
  input input: String,
  acc acc: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), String) {
  case input {
    "" -> #(acc, "")
    _ -> {
      let #(prefix, delim, rest) = splitter.split(sp.key, input)
      let acc = case prefix {
        "" -> acc
        _ -> [T(Token(kind: types.BareKey, text: prefix)), ..acc]
      }
      case delim {
        "" -> #(acc, "")
        "=" -> #([T(Token(kind: types.Equals, text: "")), ..acc], rest)
        "." ->
          consume_key_and_eq(sp:, input: rest, acc: [
            T(Token(kind: types.Dot, text: "")),
            ..acc
          ])
        " " | "\t" -> {
          let #(ws, rest_after) = core.scan_ws(delim, rest)
          consume_key_and_eq(sp:, input: rest_after, acc: [
            T(Token(kind: types.Whitespace, text: ws)),
            ..acc
          ])
        }
        "\"" -> {
          let #(str_tok, rest_after, _, _) =
            scan_basic_string(sp:, input: rest, pending_nl: "", source_rest: "")
          consume_key_and_eq(sp:, input: rest_after, acc: [T(str_tok), ..acc])
        }
        "'" -> {
          let #(str_tok, rest_after, _, _) =
            scan_literal_string(
              sp:,
              input: rest,
              pending_nl: "",
              source_rest: "",
            )
          consume_key_and_eq(sp:, input: rest_after, acc: [T(str_tok), ..acc])
        }
        "[" ->
          consume_key_and_eq(sp:, input: rest, acc: [
            T(Token(kind: types.LeftBracket, text: "")),
            ..acc
          ])
        "]" ->
          consume_key_and_eq(sp:, input: rest, acc: [
            T(Token(kind: types.RightBracket, text: "")),
            ..acc
          ])
        "#" -> #([T(Token(kind: types.Comment, text: "#" <> rest)), ..acc], "")
        _ -> consume_key_and_eq(sp:, input: rest, acc:)
      }
    }
  }
}

fn maybe_emit_next_part(
  pending_nl: String,
  parts_rev: List(String),
) -> List(String) {
  use <- bool.guard(pending_nl == "", return: parts_rev)
  [pending_nl, ..parts_rev]
}
