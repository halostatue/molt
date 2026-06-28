import birdie
import gleam/int
import gleam/list
import gleam/string
import molt
import molt/types
import toml_suite

// --- Snapshot tests for each invalid TOML category ---

pub fn invalid_array_test() {
  snapshot_category("array")
}

pub fn invalid_bool_test() {
  snapshot_category("bool")
}

pub fn invalid_control_test() {
  snapshot_category("control")
}

pub fn invalid_datetime_test() {
  snapshot_category("datetime")
}

pub fn invalid_float_test() {
  snapshot_category("float")
}

pub fn invalid_inline_table_test() {
  snapshot_category("inline-table")
}

pub fn invalid_integer_test() {
  snapshot_category("integer")
}

pub fn invalid_key_test() {
  snapshot_category("key")
}

pub fn invalid_local_date_test() {
  snapshot_category("local-date")
}

pub fn invalid_local_datetime_test() {
  snapshot_category("local-datetime")
}

pub fn invalid_local_time_test() {
  snapshot_category("local-time")
}

pub fn invalid_spec_1_0_0_test() {
  snapshot_category("spec-1.0.0")
}

pub fn invalid_spec_1_1_0_test() {
  snapshot_category("spec-1.1.0")
}

pub fn invalid_string_test() {
  snapshot_category("string")
}

pub fn invalid_table_test() {
  snapshot_category("table")
}

fn snapshot_category(category: String) {
  let assert Ok(files) =
    toml_suite.read_fixture_directory("invalid/" <> category)

  let output =
    files
    |> list.map(fn(entry) {
      let #(file, content) = entry
      case molt.parse_bits(content) {
        Ok(doc) ->
          case molt.document_errors(doc) {
            [] -> file <> "\n  (no errors detected)"
            errors -> file <> "\n" <> format_errors(errors)
          }
        Error(_) -> file <> "\n  (rejected at parse level)"
      }
    })
    |> string.join("\n\n")

  birdie.snap(content: output, title: "invalid/" <> category)
}

fn format_errors(errors: List(types.SyntaxError)) -> String {
  list.map(errors, format_error)
  |> string.join("\n")
}

fn format_error(error: types.SyntaxError) -> String {
  let types.SyntaxError(kind:, path:, span:) = error
  let types.Span(line:, col:, offset:) = span
  let loc =
    "  "
    <> int.to_string(line)
    <> ":"
    <> int.to_string(col)
    <> " (offset "
    <> int.to_string(offset)
    <> ")"
  let kind_str = case kind {
    types.DuplicateKey(key:, original:) ->
      "duplicate key: "
      <> key
      <> " (originally at "
      <> format_span(original)
      <> ")"
    types.DuplicateTable(original:) ->
      "duplicate table (originally at " <> format_span(original) <> ")"
    types.KeyIsScalar(key:, original:) ->
      "key is scalar: "
      <> key
      <> " (originally at "
      <> format_span(original)
      <> ")"
    types.KeyIsInlineTable(key:, original:) ->
      "key is inline table: "
      <> key
      <> " (originally at "
      <> format_span(original)
      <> ")"
    types.KeyIsArray(key:, original:) ->
      "key is array: "
      <> key
      <> " (originally at "
      <> format_span(original)
      <> ")"
    types.UnterminatedString -> "unterminated string"
    types.UnterminatedMultilineString -> "unterminated multiline string"
    types.BadValue(text:) -> "bad value: " <> truncate(text, 40)
    types.InvalidKeySyntax -> "invalid key syntax"
    types.MissingValue -> "missing value"
    types.ExtraEquals -> "extra equals sign"
    types.MultipleValues -> "multiple values"
    types.EmptyTableHeader -> "empty table header"
    types.MalformedTableHeader -> "malformed table header"
    types.UnterminatedArray -> "unterminated array"
    types.MisplacedArraySeparator -> "misplaced array separator"
    types.UnterminatedInlineTable -> "unterminated inline table"
    types.DuplicateKeyInInlineTable(key:) ->
      "duplicate key in inline table: " <> key
    types.InvalidBareValueInInlineTable -> "invalid bare value in inline table"
    types.MisplacedInlineTableSeparator -> "misplaced inline table separator"
    types.UnparsableContent -> "unparsable content"
    types.NoValidTomlStructure -> "no valid toml structure"
  }
  let path_str = case path {
    [] -> ""
    _ -> " [" <> string.join(path, ".") <> "]"
  }
  loc <> " " <> kind_str <> path_str
}

fn format_span(span: types.Span) -> String {
  int.to_string(span.line) <> ":" <> int.to_string(span.col)
}

fn truncate(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) <> "..."
    False -> s
  }
}

// --- Property: count mode and enrich mode agree on the violation tally ---
// `molt.error_count` (count mode, set at parse) and `molt.document_errors`
// (enrich mode, on demand) run the *same* rule walk. They must report the same
// number of violations for every document, or the two modes have drifted. This
// checks the invariant across every invalid fixture in the suite.

pub fn count_matches_document_errors_length_test() {
  list.each(invalid_categories(), fn(category) {
    let assert Ok(files) =
      toml_suite.read_fixture_directory("invalid/" <> category)
    list.each(files, fn(entry) {
      let #(_file, content) = entry
      case molt.parse_bits(content) {
        Ok(doc) -> {
          assert molt.error_count(doc) == list.length(molt.document_errors(doc))
        }
        Error(_) -> Nil
      }
    })
  })
}

fn invalid_categories() -> List(String) {
  [
    "array", "bool", "control", "datetime", "float", "inline-table", "integer",
    "key", "local-date", "local-datetime", "local-time", "spec-1.0.0",
    "spec-1.1.0", "string", "table",
  ]
}
