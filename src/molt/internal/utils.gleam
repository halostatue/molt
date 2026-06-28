import casefold
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import greenwood.{type Token, Token}
import molt/types.{
  type Path, type TomlKind, BareKey, BasicString, IndexSegment, KeySegment,
}

pub fn toml_kind(value: TomlKind) -> String {
  case value {
    types.Array -> "array"
    types.ArrayElement -> "array_element"
    types.ArrayOfTables -> "array_of_tables"
    types.BareKey -> "bare_key"
    types.BasicString -> "basic_string"
    types.BinaryInteger -> "binary_integer"
    types.Bom -> "bom"
    types.BoolFalse -> "false"
    types.BoolTrue -> "true"
    types.Comma -> "comma"
    types.Comment -> "comment"
    types.Dot -> "dot"
    types.Equals -> "equals"
    types.Error -> "error"
    types.Float -> "float"
    types.HexInteger -> "hex_integer"
    types.Inf -> "unsigned_inf"
    types.InlineTable -> "inline_table"
    types.Integer -> "integer"
    types.InvalidValue -> "invalid_value"
    types.InvalidBasicString -> "invalid_basic_string"
    types.InvalidLiteralString -> "invalid_literal_string"
    types.InvalidMultilineBasicString -> "invalid_multiline_basic_string"
    types.InvalidMultilineLiteralString -> "invalid_multiline_literal_string"
    types.Key -> "key"
    types.KeyValue -> "key_value"
    types.LeftBrace -> "left_brace"
    types.LeftBracket -> "left_bracket"
    types.LiteralString -> "literal_string"
    types.LocalDate -> "local_date"
    types.LocalDateTime -> "local_datetime"
    types.LocalTime -> "local_time"
    types.MultilineBasicString -> "multiline_basic_string"
    types.MultilineBasicStringNl -> "multiline_basic_string_nl"
    types.MultilineLiteralString -> "multiline_literal_string"
    types.MultilineLiteralStringNl -> "multiline_literal_string_nl"
    types.NaN -> "unsigned_nan"
    types.NegInf -> "negative_inf"
    types.NegNaN -> "negative_nan"
    types.Newline -> "newline"
    types.OctalInteger -> "octal_integer"
    types.OffsetDateTime -> "offset_datetime"
    types.PostScript -> "postscript"
    types.PosInf -> "positive_inf"
    types.PosNaN -> "positive_nan"
    types.RightBrace -> "right_brace"
    types.RightBracket -> "right_bracket"
    types.Root -> "document"
    types.Table -> "table"
    types.Whitespace -> "whitespace"
  }
}

pub fn index_entry_to_string(entry: types.IndexEntry) -> String {
  case entry {
    types.IndexTable(..) -> "table"
    types.IndexArrayOfTables(..) -> "array of tables"
    types.IndexArrayOfTablesEntry(..) -> "array of tables entry"
    types.IndexImplicitTable(..) -> "implicit table"
    types.IndexScalarValue(..) -> "value"
    types.IndexInlineTableValue(..) -> "inline table"
    types.IndexArrayValue(..) -> "array"
  }
}

pub fn make_key_token(name: String) -> Token(TomlKind) {
  use <- bool.guard(is_bare_key(name), return: Token(kind: BareKey, text: name))
  Token(kind: BasicString, text: escape_key(name))
}

pub fn list_at(items items: List(a), index index: Int) -> Result(a, Nil) {
  list.drop(items, index) |> list.first()
}

pub fn path_to_string(segments: Path) -> String {
  list.map(segments, fn(segment) {
    case segment {
      KeySegment(key) -> quote_key(key)
      IndexSegment(index) -> "[" <> int.to_string(index) <> "]"
    }
  })
  |> string.join(".")
  |> string.replace(".[", "[")
}

pub fn resolve_index(index index: Int, length length: Int) -> Int {
  use <- bool.guard(index < 0, return: length + index)
  index
}

/// Resolve an Insert position. Positions live in `[0, length]` (`length` =
/// "at the end"); negative offsets in `[-length, -1]` refer to "before the
/// element at that index" (`-1` = before last element). Errors out-of-range.
pub fn resolve_insert_position(
  index index: Int,
  length length: Int,
) -> Result(Int, Nil) {
  let min = 0 - length
  case index {
    i if i >= 0 && i <= length -> Ok(i)
    i if i < 0 && i >= min -> Ok(length + i)
    _ -> Error(Nil)
  }
}

/// Return all proper prefixes of a list (all sub-lists except the full list).
pub fn all_prefixes(path segments: List(a)) -> List(List(a)) {
  do_all_prefixes(path: segments, current: [], acc: [])
}

fn do_all_prefixes(
  path segments: List(a),
  current current: List(a),
  acc acc: List(List(a)),
) -> List(List(a)) {
  case segments {
    [] | [_] -> list.reverse(acc)
    [segment, ..path] -> {
      let current = list.append(current, [segment])
      do_all_prefixes(path:, current:, acc: [current, ..acc])
    }
  }
}

/// Returns True if `key` is a valid bare TOML key
pub fn is_bare_key(key: String) -> Bool {
  key != "" && key |> string.to_graphemes |> list.all(is_bare_key_char)
}

/// Returns a quoted `key` value if the characters in the key are not valid bare
/// key values.
pub fn quote_key(key: String) -> String {
  use <- bool.guard(is_bare_key(key), return: key)
  "\"" <> escape_key(key) <> "\""
}

/// Returns `#(string, string)` split at the index. Accepted by `casefold` and
/// here only because the appropriate version of casefold hasn't yet been
/// released.
pub fn split_at(string s: String, at index: Int) -> #(String, String) {
  let len = string.length(s)

  use <- bool.guard(len < index, return: #(s, ""))
  use <- bool.lazy_guard(index >= 0, return: fn() {
    #(string.slice(s, 0, index), string.slice(s, index, len))
  })

  #(string.slice(s, 0, len + index), string.slice(s, len + index, len))
}

/// Reverses and concats the accumulator list of strings.
pub fn reverse_concat(strings: List(String)) -> String {
  strings |> list.reverse |> string.concat
}

fn is_bare_key_char(char: String) -> Bool {
  casefold.is_alnum_grapheme(char) || char == "-" || char == "_"
}

fn escape_key(key: String) -> String {
  key
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
}

pub fn unescape_basic_string(s: String) -> String {
  string.to_graphemes(s)
  |> do_unescape_basic_string([])
  |> string.concat
}

fn do_unescape_basic_string(
  s: List(String),
  acc: List(String),
) -> List(String) {
  case s {
    [] -> list.reverse(acc)
    ["\\", ..rest] -> {
      let #(ch, rest) = interpret_basic_string_escape(rest)
      do_unescape_basic_string(rest, [ch, ..acc])
    }
    [ch, ..rest] -> do_unescape_basic_string(rest, [ch, ..acc])
  }
}

fn interpret_basic_string_escape(
  input: List(String),
) -> #(String, List(String)) {
  case input {
    [] -> #("\\", [])
    ["b", ..rest] -> #("\u{0008}", rest)
    ["t", ..rest] -> #("\t", rest)
    ["n", ..rest] -> #("\n", rest)
    ["f", ..rest] -> #("\u{000C}", rest)
    ["r", ..rest] -> #("\r", rest)
    ["\"", ..rest] -> #("\"", rest)
    ["\\", ..rest] -> #("\\", rest)
    ["u", ..rest] -> decode_unicode(rest, 4)
    ["U", ..rest] -> decode_unicode(rest, 8)
    ["x", ..rest] -> decode_unicode(rest, 2)
    _ ->
      case skip_line_continuation(input) {
        Some(rest) -> #("", rest)
        None ->
          case input {
            [ch, ..rest] -> #("\\" <> ch, rest)
            [] -> #("\\", [])
          }
      }
  }
}

fn skip_line_continuation(input: List(String)) -> Option(List(String)) {
  case input {
    [" ", ..rest] | ["\t", ..rest] -> skip_line_continuation(rest)
    ["\r", "\n", ..rest] | ["\n", ..rest] | ["\r", ..rest] ->
      Some(skip_continuation_whitespace(rest))
    _ -> None
  }
}

fn skip_continuation_whitespace(input: List(String)) -> List(String) {
  case input {
    [" ", ..rest] | ["\t", ..rest] | ["\n", ..rest] | ["\r", ..rest] ->
      skip_continuation_whitespace(rest)
    _ -> input
  }
}

fn decode_unicode(input: List(String), n: Int) -> #(String, List(String)) {
  let #(hex, rest) = list.split(input, n)
  let hex = string.concat(hex)
  case int.base_parse(hex, 16) {
    Ok(codepoint) ->
      case string.utf_codepoint(codepoint) {
        Ok(cp) -> #(string.from_utf_codepoints([cp]), rest)
        Error(Nil) -> #("\\u" <> hex, rest)
      }
    Error(Nil) -> #("\\u" <> hex, rest)
  }
}
