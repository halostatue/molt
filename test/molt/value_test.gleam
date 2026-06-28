import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import molt
import molt/cst
import molt/error
import molt/types.{KeySegment}
import molt/value

pub fn float_test() {
  assert "3.14" == value.float(3.14) |> value.to_toml_value
  assert "3.0e53" == value.float(3.0e53) |> value.to_toml_value
  assert "-3.14" == value.float(-3.14) |> value.to_toml_value
  assert "3.0e-14" == value.float(3.0e-14) |> value.to_toml_value

  assert "float" == value.float(3.14) |> value.type_of
  assert "float" == value.float(3.0e14) |> value.type_of
  assert "float" == value.float(-3.14) |> value.type_of
  assert "float" == value.float(3.0e-14) |> value.type_of
}

pub fn bool_true_test() {
  assert "true" == value.bool(True) |> value.to_toml_value
  assert "false" == value.bool(False) |> value.to_toml_value
  assert "boolean" == value.bool(True) |> value.type_of
  assert "boolean" == value.bool(False) |> value.type_of
}

pub fn datetime_test() {
  let assert Ok(v) = value.datetime("2024-01-01T00:00:00Z")
  assert "2024-01-01T00:00:00Z" == value.to_toml_value(v)
  assert "offset_datetime" == value.type_of(v)

  let assert Ok(v) = value.datetime("2024-01-01T00:00Z")
  assert "2024-01-01T00:00Z" == value.to_toml_value(v)
  assert "offset_datetime" == value.type_of(v)

  let assert Ok(v) = value.datetime("2024-01-01T00:00:00")
  assert "2024-01-01T00:00:00" == value.to_toml_value(v)
  assert "local_datetime" == value.type_of(v)

  let assert Ok(v) = value.datetime("2024-01-01T00:00")
  assert "2024-01-01T00:00" == value.to_toml_value(v)
  assert "local_datetime" == value.type_of(v)

  let assert Ok(v) = value.datetime("2024-01-01")
  assert "2024-01-01" == value.to_toml_value(v)
  assert "local_date" == value.type_of(v)

  let assert Ok(v) = value.datetime("12:30:00")
  let assert "12:30:00" = value.to_toml_value(v)
  assert "local_time" == value.type_of(v)

  let assert Ok(v) = value.datetime("12:30")
  let assert "12:30" = value.to_toml_value(v)
  assert "local_time" == value.type_of(v)

  let assert Error(error.ValueParseError(
    Some("offset_datetime, local_datetime, local_date, or local_time"),
    "3.14",
  )) = value.datetime("3.14")
}

pub fn offset_datetime_test() {
  let assert Ok(v) = value.offset_datetime("2024-01-01T00:00:00Z")
  assert "2024-01-01T00:00:00Z" == value.to_toml_value(v)
  assert "offset_datetime" == value.type_of(v)

  let assert Ok(v) = value.offset_datetime("2024-01-01T00:00Z")
  assert "2024-01-01T00:00Z" == value.to_toml_value(v)
  assert "offset_datetime" == value.type_of(v)

  let assert Error(error.ValueParseError(Some("offset_datetime"), "2024-01-01")) =
    value.offset_datetime("2024-01-01")
}

pub fn local_datetime_test() {
  let assert Ok(v) = value.local_datetime("2024-01-01T00:00:00")
  assert "2024-01-01T00:00:00" == value.to_toml_value(v)
  assert "local_datetime" == value.type_of(v)

  let assert Ok(v) = value.local_datetime("2024-01-01T00:00")
  assert "2024-01-01T00:00" == value.to_toml_value(v)
  assert "local_datetime" == value.type_of(v)

  let assert Error(error.ValueParseError(Some("local_datetime"), "2024-01-01")) =
    value.local_datetime("2024-01-01")
}

pub fn local_date_test() {
  let assert Ok(v) = value.local_date("2024-01-01")
  assert "2024-01-01" == value.to_toml_value(v)
  assert "local_date" == value.type_of(v)

  let assert Error(error.ValueParseError(
    Some("local_date"),
    "2024-01-01T00:00:00",
  )) = value.local_date("2024-01-01T00:00:00")
}

pub fn local_time_test() {
  let assert Ok(v) = value.local_time("12:30:00")
  let assert "12:30:00" = value.to_toml_value(v)
  assert "local_time" == value.type_of(v)

  let assert Ok(v) = value.local_time("12:30")
  let assert "12:30" = value.to_toml_value(v)
  assert "local_time" == value.type_of(v)

  let assert Error(error.ValueParseError(
    Some("local_time"),
    "2024-01-01T00:00:00",
  )) = value.local_time("2024-01-01T00:00:00")
}

pub fn unwrap_datetime_test() {
  let assert Ok(odt) = value.offset_datetime("2024-01-01T00:00:00Z")
  let assert Ok("2024-01-01T00:00:00Z") = value.unwrap_datetime(odt)

  let assert Ok(odt) = value.offset_datetime("2024-01-01T00:00Z")
  let assert Ok("2024-01-01T00:00Z") = value.unwrap_datetime(odt)

  let assert Ok(ldt) = value.local_datetime("2024-01-01T00:00:00")
  let assert Ok("2024-01-01T00:00:00") = value.unwrap_datetime(ldt)

  let assert Ok(ldt) = value.local_datetime("2024-01-01T00:00")
  let assert Ok("2024-01-01T00:00") = value.unwrap_datetime(ldt)

  let assert Ok(ld) = value.local_date("2024-01-01")
  let assert Ok("2024-01-01") = value.unwrap_datetime(ld)

  let assert Ok(lt) = value.local_time("12:30:00")
  let assert Ok("12:30:00") = value.unwrap_datetime(lt)

  let assert Ok(lt) = value.local_time("12:30")
  let assert Ok("12:30") = value.unwrap_datetime(lt)
}

pub fn unwrap_datetime_type_mismatch_test() {
  let assert Error(error.TypeMismatch(
    expected: "offset_datetime, local_datetime, local_date, or local_time",
    ..,
  )) = value.unwrap_datetime(value.string("2024-01-01"))
}

pub fn int_test() {
  assert "4095" == value.int(4095) |> value.to_toml_value
  assert "0xFFF" == value.hex_int(4095) |> value.to_toml_value
  assert "0o7777" == value.octal_int(4095) |> value.to_toml_value
  assert "0b111111111111" == value.binary_int(4095) |> value.to_toml_value

  assert "integer" == value.int(4095) |> value.type_of
  assert "integer" == value.hex_int(4095) |> value.type_of
  assert "integer" == value.octal_int(4095) |> value.type_of
  assert "integer" == value.binary_int(4095) |> value.type_of

  assert Some("decimal") == value.int(4095) |> value.int_style
  assert Some("hex") == value.hex_int(4095) |> value.int_style
  assert Some("octal") == value.octal_int(4095) |> value.int_style
  assert Some("binary") == value.binary_int(4095) |> value.int_style
  assert None == value.float(3.14) |> value.int_style
}

pub fn basic_string_test() {
  let basic = value.basic_string("hello")

  assert "\"hello\"" == value.to_toml_value(basic)
  assert "string" == value.type_of(basic)
  assert Some("basic") == value.string_style(basic)
}

pub fn literal_string_test() {
  let assert Ok(literal) = value.literal_string("say \"hello\"")

  assert "'say \"hello\"'" == value.to_toml_value(literal)
  assert "string" == value.type_of(literal)
  assert Some("literal") == value.string_style(literal)
}

pub fn literal_string_rejects_single_quote_test() {
  let assert Error(error.ValueParseError(
    expected: Some("literal_string"),
    text: "it's",
  )) = value.literal_string("it's")
}

pub fn literal_string_rejects_newline_test() {
  let assert Error(error.ValueParseError(expected: Some("literal_string"), ..)) =
    value.literal_string("line1\nline2")
}

pub fn literal_string_rejects_control_char_test() {
  let assert Error(error.ValueParseError(expected: Some("literal_string"), ..)) =
    value.literal_string("a\u{0007}b")
}

pub fn multitline_basic_string_test() {
  let multiline_basic = value.multiline_basic_string("hello\nthere\n")

  assert "\"\"\"\nhello\nthere\n\"\"\"" == value.to_toml_value(multiline_basic)
  assert "string" == value.type_of(multiline_basic)
  assert Some("multiline_basic") == value.string_style(multiline_basic)
}

pub fn multiline_literal_string_test() {
  let assert Ok(multiline_literal) =
    value.multiline_literal_string("hello\n\"there\"\n")

  assert "'''\nhello\n\"there\"\n'''" == value.to_toml_value(multiline_literal)
  assert "string" == value.type_of(multiline_literal)
  assert Some("multiline_literal") == value.string_style(multiline_literal)
}

pub fn multiline_literal_string_rejects_triple_quote_test() {
  let assert Error(error.ValueParseError(
    expected: Some("multiline_literal_string"),
    ..,
  )) = value.multiline_literal_string("end'''here")
}

pub fn multiline_literal_string_rejects_control_char_test() {
  let assert Error(error.ValueParseError(
    expected: Some("multiline_literal_string"),
    ..,
  )) = value.multiline_literal_string("a\u{0007}b")
}

pub fn string_test() {
  // Contains both " and ' → escaped basic string
  let basic = value.string("it's \"fine\"")
  // Contains " but no ' → literal quote
  let literal = value.string("say \"hello\"")
  // Multiline, no backslash → basic multiline
  let multiline_basic = value.string("line1\nline2")
  // Multiline with backslash, no ''' → literal multiline
  let multiline_literal = value.string("path\\to\nfile")

  assert Some("basic") == value.string_style(basic)
  assert "\"it's \\\"fine\\\"\"" == value.to_toml_value(basic)

  assert Some("literal") == value.string_style(literal)
  assert "'say \"hello\"'" == value.to_toml_value(literal)

  assert Some("multiline_basic") == value.string_style(multiline_basic)
  assert "\"\"\"\nline1\nline2\"\"\"" == value.to_toml_value(multiline_basic)

  assert Some("multiline_literal") == value.string_style(multiline_literal)
  assert "'''\npath\\to\nfile'''" == value.to_toml_value(multiline_literal)

  assert None == value.string_style(value.int(3))
}

// A backslash with no other obstacle takes the literal form, sparing the
// escaping a basic string would need (e.g. Windows paths).
pub fn string_prefers_literal_for_backslash_test() {
  let v = value.string("C:\\tmp\\bin")
  assert Some("literal") == value.string_style(v)
  assert "'C:\\tmp\\bin'" == value.to_toml_value(v)
}

// A multiline value with `"` but no backslash now takes the literal form: molt's
// multiline-basic emitter escapes every `"`, so literal spares that escaping.
pub fn string_multiline_prefers_literal_for_quotes_test() {
  let v = value.string("say \"hi\"\nbye")
  assert Some("multiline_literal") == value.string_style(v)
  assert "'''\nsay \"hi\"\nbye'''" == value.to_toml_value(v)
}

// Regression: a value that triggers the literal branch (here via `\`) but also
// holds a control char a literal string cannot represent must fall back to a
// basic string, not emit an invalid literal. The ESC is escaped, never raw.
pub fn string_control_char_falls_back_to_basic_test() {
  let v = value.string("\u{001B}\\")
  assert Some("basic") == value.string_style(v)
  assert "\"\\u001B\\\\\"" == value.to_toml_value(v)

  // and it round-trips through a real parse as valid TOML
  let assert Ok(doc) = molt.parse("k = " <> value.to_toml_value(v))
  let assert Ok(got) = molt.get(doc, "k")
  assert Ok("\u{001B}\\") == value.unwrap_string(got)
}

// Backspace (U+0008) can never live in a literal string; it must be a basic
// string using the `\b` escape, even alongside a `"` that triggers literal.
pub fn string_backspace_falls_back_to_basic_test() {
  let v = value.string("\"\u{0008}")
  assert Some("basic") == value.string_style(v)
  assert "\"\\\"\\b\"" == value.to_toml_value(v)
}

// Same regression for the multiline branch: backslash triggers literal, but the
// ESC forces the basic fallback. The output must contain no raw control byte.
pub fn string_multiline_control_falls_back_to_basic_test() {
  let v = value.string("a\\\u{001B}\nb")
  assert Some("multiline_basic") == value.string_style(v)
  assert False == string.contains(value.to_toml_value(v), "\u{001B}")

  let assert Ok(doc) = molt.parse("k = " <> value.to_toml_value(v))
  let assert Ok(got) = molt.get(doc, "k")
  assert Ok("a\\\u{001B}\nb") == value.unwrap_string(got)
}

// A multiline value that triggers the literal branch but contains `'''` (which a
// literal string cannot hold) falls back to a basic string.
pub fn string_multiline_triple_quote_falls_back_to_basic_test() {
  let v = value.string("x'''y\n\\z")
  assert Some("multiline_basic") == value.string_style(v)
}

pub fn infinity_test() {
  let unsigned = value.infinity()
  let unsigned2 = value.signed_infinity(value.Unsigned)
  let positive = value.signed_infinity(value.Positive)
  let negative = value.signed_infinity(value.Negative)

  assert "inf" == value.to_toml_value(unsigned)
  assert "inf" == value.to_toml_value(unsigned2)
  assert "+inf" == value.to_toml_value(positive)
  assert "-inf" == value.to_toml_value(negative)

  assert "infinity" == value.type_of(unsigned)
  assert "infinity" == value.type_of(unsigned2)
  assert "infinity" == value.type_of(positive)
  assert "infinity" == value.type_of(negative)
}

pub fn nan_test() {
  let unsigned = value.nan()
  let unsigned2 = value.signed_nan(value.Unsigned)
  let positive = value.signed_nan(value.Positive)
  let negative = value.signed_nan(value.Negative)

  assert "nan" == value.to_toml_value(unsigned)
  assert "nan" == value.to_toml_value(unsigned2)
  assert "+nan" == value.to_toml_value(positive)
  assert "-nan" == value.to_toml_value(negative)

  assert "nan" == value.type_of(unsigned)
  assert "nan" == value.type_of(unsigned2)
  assert "nan" == value.type_of(positive)
  assert "nan" == value.type_of(negative)
}

// --- Compound types ---

pub fn table_test() {
  let table = value.table([#("a", value.int(1)), #("b", value.string("x"))])
  assert "{a = 1, b = \"x\"}" == value.to_toml_value(table)
  assert "inline_table" == value.type_of(table)
}

pub fn array_test() {
  let infer = value.array([value.int(1), value.int(2), value.string("x")])
  assert "[1, 2, \"x\"]" == value.to_toml_value(infer)
  assert "array" == value.type_of(infer)
}

// `is_valid` works by round-tripping `to_toml` output back through the parser,
// so the meaningful case is a compound value (table holding an array) whose
// emitted text must re-parse cleanly. Asserting True for every leaf constructor
// is tautological, so only the compound round-trip is kept.
pub fn is_valid_test() {
  let nested =
    value.table([#("a", value.array([value.int(1), value.string("x")]))])
  assert nested |> value.is_valid
}

fn describe(
  r: Result(value.Value, error.MoltError),
  f: fn(value.Value) -> Option(String),
) -> String {
  result.map(r, f)
  |> option.from_result
  |> option.flatten
  |> option.unwrap(or: "")
}

fn type_of(r: Result(value.Value, error.MoltError)) -> String {
  result.map(r, value.type_of)
  |> result.unwrap("")
}

fn to_toml_value(r: Result(value.Value, error.MoltError)) -> String {
  result.map(r, value.to_toml_value)
  |> result.unwrap("")
}

pub fn parse_value_test() {
  assert "basic"
    == value.parse_value("\"it's \\\"fine\\\"\"")
    |> describe(value.string_style)

  assert "literal"
    == value.parse_value("'say \"hello\"'")
    |> describe(value.string_style)

  assert "multiline_basic"
    == value.parse_value("\"\"\"line1\nline2\"\"\"")
    |> describe(value.string_style)

  assert "multiline_literal"
    == value.parse_value("'''path\\to\nfile'''")
    |> describe(value.string_style)

  assert "decimal" == value.parse_value("3") |> describe(value.int_style)
  assert "hex" == value.parse_value("0x3") |> describe(value.int_style)
  assert "octal" == value.parse_value("0o3") |> describe(value.int_style)
  assert "binary" == value.parse_value("0b111") |> describe(value.int_style)

  // parse_value retains the source spelling verbatim: underscores, hex casing.
  assert "1_000" == value.parse_value("1_000") |> to_toml_value
  assert "0xFF00FF" == value.parse_value("0xFF00FF") |> to_toml_value

  assert "float" == value.parse_value("0.3") |> type_of
  assert "float" == value.parse_value("0e3") |> type_of
  assert "float" == value.parse_value("0.3e3") |> type_of

  assert "inf" == value.parse_value("inf") |> to_toml_value
  assert "+inf" == value.parse_value("+inf") |> to_toml_value
  assert "-inf" == value.parse_value("-inf") |> to_toml_value

  assert "nan" == value.parse_value("nan") |> to_toml_value
  assert "+nan" == value.parse_value("+nan") |> to_toml_value
  assert "-nan" == value.parse_value("-nan") |> to_toml_value

  assert "boolean" == value.parse_value("true") |> type_of
  assert "boolean" == value.parse_value("false") |> type_of

  assert "offset_datetime"
    == value.parse_value("2024-01-01T00:00:00Z") |> type_of
  assert "local_datetime" == value.parse_value("2024-01-01T00:00:00") |> type_of
  assert "local_date" == value.parse_value("2024-01-01") |> type_of
  assert "local_time" == value.parse_value("12:30:00") |> type_of

  assert "inline_table"
    == value.parse_value("{a = 1, b = \"x\"}")
    |> result.map(value.type_of)
    |> result.unwrap("")

  assert "array"
    == value.parse_value("[1, 2, 3]")
    |> result.map(value.type_of)
    |> result.unwrap("")
}

// ---------------------------------------------------------------------------
// as_inline_table
// ---------------------------------------------------------------------------

pub fn as_inline_table_identity_test() {
  let tbl = value.table([#("k", value.int(1))])
  let assert Ok(inline) = value.as_inline_table(tbl)
  assert value.to_toml_value(inline) == "{k = 1}"
}

pub fn as_inline_table_from_section_table_test() {
  let assert Ok(section) =
    value.as_section_table(value.table([#("k", value.int(1))]))
  let assert Ok(inline) = value.as_inline_table(section)
  assert value.to_toml_value(inline) == "{k = 1}"
}

pub fn as_inline_table_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "table or inline_table", ..)) =
    value.as_inline_table(value.int(1))
}

// ---------------------------------------------------------------------------
// as_array / as_array_of_tables
// ---------------------------------------------------------------------------

pub fn as_array_identity_test() {
  let arr = value.array([value.int(1), value.int(2)])
  let assert Ok(result) = value.as_array(arr)
  assert value.to_toml_value(result) == "[1, 2]"
}

pub fn as_array_from_array_of_tables_test() {
  let assert Ok(aot) =
    value.as_array_of_tables(
      value.array([
        value.table([#("k", value.int(1))]),
      ]),
    )
  let assert Ok(arr) = value.as_array(aot)
  assert value.type_of(arr) == "array"
}

pub fn as_array_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "array or array_of_tables", ..)) =
    value.as_array(value.int(1))
}

pub fn as_array_of_tables_identity_test() {
  let assert Ok(aot) =
    value.as_array_of_tables(
      value.array([
        value.table([#("k", value.int(1))]),
      ]),
    )
  let assert Ok(result) = value.as_array_of_tables(aot)
  assert value.type_of(result) == "array_of_tables"
}

pub fn as_array_of_tables_from_array_test() {
  let arr = value.array([value.table([#("k", value.int(1))])])
  let assert Ok(aot) = value.as_array_of_tables(arr)
  assert value.type_of(aot) == "array_of_tables"
}

pub fn as_array_of_tables_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "array or array_of_tables", ..)) =
    value.as_array_of_tables(value.int(1))
}

// ---------------------------------------------------------------------------
// as_decimal_int / as_hex_int / as_octal_int / as_binary_int
// ---------------------------------------------------------------------------

pub fn as_decimal_int_from_hex_test() {
  let assert Ok(v) = value.as_decimal_int(value.hex_int(255))
  assert value.to_toml_value(v) == "255"
}

pub fn as_decimal_int_type_mismatch_test() {
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "integer",
    got: "boolean",
  )) = value.as_decimal_int(value.bool(True))
}

pub fn as_hex_int_from_decimal_test() {
  let assert Ok(v) = value.as_hex_int(value.int(255))
  assert value.to_toml_value(v) == "0xFF"
}

pub fn as_hex_int_type_mismatch_test() {
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "integer",
    got: "float",
  )) = value.as_hex_int(value.float(1.0))
}

pub fn as_octal_int_from_decimal_test() {
  let assert Ok(v) = value.as_octal_int(value.int(8))
  assert value.int_style(v) == Some("octal")
}

pub fn as_octal_int_type_mismatch_test() {
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "integer",
    got: "string",
  )) = value.as_octal_int(value.string("x"))
}

pub fn as_binary_int_from_decimal_test() {
  let assert Ok(v) = value.as_binary_int(value.int(3))
  assert value.int_style(v) == Some("binary")
}

pub fn as_binary_int_type_mismatch_test() {
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "integer",
    got: "string",
  )) = value.as_binary_int(value.string("x"))
}

// ---------------------------------------------------------------------------
// to_toml
// ---------------------------------------------------------------------------

pub fn to_toml_scalar_test() {
  let assert Ok(result) = value.to_toml(key: "x", value: value.int(42))
  assert result == "x = 42"
}

pub fn to_toml_table_test() {
  let assert Ok(section) =
    value.as_section_table(value.table([#("port", value.int(8080))]))
  let assert Ok(result) = value.to_toml(key: "server", value: section)
  assert result == "[server]\nport = 8080\n"
}

pub fn to_toml_array_of_tables_test() {
  let assert Ok(aot) =
    value.as_array_of_tables(
      value.array([
        value.table([#("name", value.string("a"))]),
      ]),
    )
  let assert Ok(result) = value.to_toml(key: "items", value: aot)
  assert result == "[[items]]\nname = \"a\"\n"
}

// ---------------------------------------------------------------------------
// from_cst
// ---------------------------------------------------------------------------

fn parse_kv(input: String) {
  let assert Ok(doc) = molt.parse(input)
  cst.from_document(doc)
}

pub fn from_cst_integer_test() {
  let node = parse_kv("x = 42\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "integer" == value.type_of(v)
  assert "42" == value.to_toml_value(v)
}

pub fn from_cst_hex_integer_test() {
  let node = parse_kv("x = 0xDEAD\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "integer" == value.type_of(v)
  assert "0xDEAD" == value.to_toml_value(v)
}

pub fn from_cst_float_test() {
  let node = parse_kv("x = 3.14\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "float" == value.type_of(v)
  assert "3.14" == value.to_toml_value(v)
}

pub fn from_cst_float_exponent_test() {
  let node = parse_kv("x = 1e3\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "float" == value.type_of(v)
  assert "1e3" == value.to_toml_value(v)
}

pub fn from_cst_bool_test() {
  let node = parse_kv("x = true\ny = false\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  assert "boolean" == value.type_of(value.from_cst(kv))
  assert "true" == value.to_toml_value(value.from_cst(kv))

  let assert Ok(kv) = cst.get(node:, path: [KeySegment("y")])
  assert "false" == value.to_toml_value(value.from_cst(kv))
}

pub fn from_cst_basic_string_test() {
  let node = parse_kv("x = \"hello world\"\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "string" == value.type_of(v)
  assert "\"hello world\"" == value.to_toml_value(v)
}

pub fn from_cst_literal_string_test() {
  let node = parse_kv("x = 'no escapes'\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "string" == value.type_of(v)
  assert "'no escapes'" == value.to_toml_value(v)
}

pub fn from_cst_datetime_test() {
  let node = parse_kv("x = 2024-01-15T10:30:00Z\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "offset_datetime" == value.type_of(v)
  assert "2024-01-15T10:30:00Z" == value.to_toml_value(v)
}

pub fn from_cst_inline_array_test() {
  let node = parse_kv("x = [1, 2, 3]\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "array" == value.type_of(v)
  assert "[1, 2, 3]" == value.to_toml_value(v)
}

pub fn from_cst_inline_table_test() {
  let node = parse_kv("x = {a = 1, b = \"hi\"}\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "inline_table" == value.type_of(v)
  assert "{a = 1, b = \"hi\"}" == value.to_toml_value(v)
}

pub fn from_cst_inf_test() {
  let node = parse_kv("x = inf\ny = +inf\nz = -inf\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  assert "inf" == value.to_toml_value(value.from_cst(kv))

  let assert Ok(kv) = cst.get(node:, path: [KeySegment("y")])
  assert "+inf" == value.to_toml_value(value.from_cst(kv))

  let assert Ok(kv) = cst.get(node:, path: [KeySegment("z")])
  assert "-inf" == value.to_toml_value(value.from_cst(kv))
}

pub fn from_cst_nan_test() {
  let node = parse_kv("x = nan\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  assert "nan" == value.to_toml_value(value.from_cst(kv))
}

pub fn from_cst_escaped_string_test() {
  let node = parse_kv("x = \"hello\\tworld\"\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "string" == value.type_of(v)
}

pub fn from_cst_nested_array_test() {
  let node = parse_kv("x = [[1, 2], [3, 4]]\n")
  let assert Ok(kv) = cst.get(node:, path: [KeySegment("x")])
  let v = value.from_cst(kv)
  assert "array" == value.type_of(v)
  assert "[[1, 2], [3, 4]]" == value.to_toml_value(v)
}

// ---------------------------------------------------------------------------
// array_get_at
// ---------------------------------------------------------------------------

pub fn array_get_at_test() {
  let arr = value.array([value.int(10), value.int(20), value.int(30)])
  let assert Ok(v) = value.array_get_at(value: arr, index: 0)
  assert "10" == value.to_toml_value(v)

  let assert Ok(v) = value.array_get_at(value: arr, index: 2)
  assert "30" == value.to_toml_value(v)

  let assert Ok(v) = value.array_get_at(value: arr, index: -1)
  assert "30" == value.to_toml_value(v)

  let assert Ok(v) = value.array_get_at(value: arr, index: -3)
  assert "10" == value.to_toml_value(v)
}

pub fn array_get_at_out_of_range_test() {
  let arr = value.array([value.int(10), value.int(20), value.int(30)])
  let assert Error(error.ValueIndexOutOfRange(index: 3, length: 3)) =
    value.array_get_at(value: arr, index: 3)
  let assert Error(error.ValueIndexOutOfRange(index: -4, length: 3)) =
    value.array_get_at(value: arr, index: -4)
}

pub fn array_get_at_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "array", ..)) =
    value.array_get_at(value: value.int(1), index: 0)
}

// ---------------------------------------------------------------------------
// array_replace_at
// ---------------------------------------------------------------------------

pub fn array_replace_at_test() {
  let arr = value.array([value.int(1), value.int(2), value.int(3)])
  let assert Ok(result) =
    value.array_replace_at(value: arr, index: 1, new: value.int(99))
  assert "[1, 99, 3]" == value.to_toml_value(result)

  let assert Ok(result) =
    value.array_replace_at(value: arr, index: -1, new: value.int(99))
  assert "[1, 2, 99]" == value.to_toml_value(result)

  let assert Ok(result) =
    value.array_replace_at(value: arr, index: 0, new: value.int(99))
  assert "[99, 2, 3]" == value.to_toml_value(result)
}

pub fn array_replace_at_out_of_range_test() {
  let arr = value.array([value.int(1), value.int(2), value.int(3)])
  let assert Error(error.ValueIndexOutOfRange(index: 3, length: 3)) =
    value.array_replace_at(value: arr, index: 3, new: value.int(99))
  let assert Error(error.ValueIndexOutOfRange(index: -4, length: 3)) =
    value.array_replace_at(value: arr, index: -4, new: value.int(99))
}

pub fn array_replace_at_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "array", ..)) =
    value.array_replace_at(value: value.int(1), index: 0, new: value.int(99))
}

// ---------------------------------------------------------------------------
// array_remove_at
// ---------------------------------------------------------------------------

pub fn array_remove_at_test() {
  let arr = value.array([value.int(1), value.int(2), value.int(3)])
  let assert Ok(result) = value.array_remove_at(value: arr, index: 1)
  assert "[1, 3]" == value.to_toml_value(result)

  let assert Ok(result) = value.array_remove_at(value: arr, index: -1)
  assert "[1, 2]" == value.to_toml_value(result)

  let assert Ok(result) = value.array_remove_at(value: arr, index: 0)
  assert "[2, 3]" == value.to_toml_value(result)
}

pub fn array_remove_at_out_of_range_test() {
  let arr = value.array([value.int(1), value.int(2), value.int(3)])
  let assert Error(error.ValueIndexOutOfRange(index: 3, length: 3)) =
    value.array_remove_at(value: arr, index: 3)
  let assert Error(error.ValueIndexOutOfRange(index: -4, length: 3)) =
    value.array_remove_at(value: arr, index: -4)
}

pub fn array_remove_at_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "array", ..)) =
    value.array_remove_at(value: value.int(1), index: 0)
}

// ---------------------------------------------------------------------------
// array_insert_at
// ---------------------------------------------------------------------------

pub fn array_insert_at_test() {
  let arr = value.array([value.int(1), value.int(2), value.int(3)])
  let assert Ok(result) =
    value.array_insert_at(value: arr, index: 1, new: value.int(99))
  assert "[1, 99, 2, 3]" == value.to_toml_value(result)

  let assert Ok(result) =
    value.array_insert_at(value: arr, index: 0, new: value.int(99))
  assert "[99, 1, 2, 3]" == value.to_toml_value(result)

  // insert at length is valid (append)
  let assert Ok(result) =
    value.array_insert_at(value: arr, index: 3, new: value.int(99))
  assert "[1, 2, 3, 99]" == value.to_toml_value(result)

  let assert Ok(result) =
    value.array_insert_at(value: arr, index: -1, new: value.int(99))
  assert "[1, 2, 99, 3]" == value.to_toml_value(result)
}

pub fn array_insert_at_out_of_range_test() {
  let arr = value.array([value.int(1), value.int(2), value.int(3)])
  let assert Error(error.ValueIndexOutOfRange(index: 4, length: 3)) =
    value.array_insert_at(value: arr, index: 4, new: value.int(99))
  let assert Error(error.ValueIndexOutOfRange(index: -4, length: 3)) =
    value.array_insert_at(value: arr, index: -4, new: value.int(99))
}

pub fn array_insert_at_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "array", ..)) =
    value.array_insert_at(value: value.int(1), index: 0, new: value.int(99))
}

// ---------------------------------------------------------------------------
// array_append
// ---------------------------------------------------------------------------

pub fn array_append_test() {
  let arr = value.array([value.int(1), value.int(2)])
  let assert Ok(result) = value.array_append(value: arr, new: value.int(3))
  assert "[1, 2, 3]" == value.to_toml_value(result)
}

pub fn array_append_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "array", ..)) =
    value.array_append(value: value.int(1), new: value.int(99))
}

// ---------------------------------------------------------------------------
// unwrap helpers
// ---------------------------------------------------------------------------

pub fn unwrap_int_or_test() {
  assert 42 == value.unwrap_int_or(value.int(42), 0)
  assert 0 == value.unwrap_int_or(value.string("nope"), 0)
}

pub fn unwrap_float_test() {
  let assert Ok(3.14) = value.unwrap_float(value.float(3.14))
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "float",
    got: "integer",
  )) = value.unwrap_float(value.int(1))
}

pub fn unwrap_float_or_test() {
  assert 3.14 == value.unwrap_float_or(value.float(3.14), 0.0)
  assert 0.0 == value.unwrap_float_or(value.int(1), 0.0)
}

pub fn unwrap_bool_or_test() {
  assert True == value.unwrap_bool_or(value.bool(True), False)
  assert False == value.unwrap_bool_or(value.int(1), False)
}

// ---------------------------------------------------------------------------
// table operations
// ---------------------------------------------------------------------------

pub fn table_to_dict_test() {
  let tbl = value.table([#("a", value.int(1)), #("b", value.int(2))])
  let assert Ok(d) = value.table_to_dict(tbl)
  let assert Ok(a) = dict.get(d, "a")
  assert "1" == value.to_toml_value(a)
  let assert Ok(b) = dict.get(d, "b")
  assert "2" == value.to_toml_value(b)
}

pub fn table_from_dict_test() {
  let d = dict.from_list([#("k", value.string("v"))])
  let tbl = value.table_from_dict(d)
  let assert Ok(v) = value.table_get_key(tbl, "k")
  assert Ok("v") == value.unwrap_string(v)
}

pub fn value_key_not_found_get_test() {
  let tbl = value.table([#("a", value.int(1))])
  let assert Error(error.ValueKeyNotFound(key: "missing")) =
    value.table_get_key(tbl, "missing")
}

pub fn value_key_not_found_rename_test() {
  let tbl = value.table([#("a", value.int(1))])
  let assert Error(error.ValueKeyNotFound(key: "gone")) =
    value.table_rename_key(tbl, from: "gone", to: "new")
}

// ---------------------------------------------------------------------------
// value.inspect
// ---------------------------------------------------------------------------

pub fn value_inspect_integer_test() {
  assert "integer(42)" == value.inspect(value.int(42))
}

pub fn value_inspect_string_test() {
  assert "string(\"hello\")" == value.inspect(value.string("hello"))
}

pub fn value_inspect_bool_test() {
  assert "boolean(true)" == value.inspect(value.bool(True))
}

pub fn value_inspect_array_test() {
  assert "array([1, 2])"
    == value.inspect(value.array([value.int(1), value.int(2)]))
}

// ---------------------------------------------------------------------------
// escape_basic: control characters
// ---------------------------------------------------------------------------

pub fn escape_basic_escapes_newline_test() {
  let s = value.basic_string("line1\nline2")
  assert "\"line1\\nline2\"" == value.to_toml_value(s)
}

pub fn escape_basic_escapes_carriage_return_test() {
  let s = value.basic_string("text\rmore")
  assert "\"text\\rmore\"" == value.to_toml_value(s)
}

pub fn escape_basic_escapes_nul_test() {
  let s = value.basic_string("a\u{0000}b")
  assert "\"a\\u0000b\"" == value.to_toml_value(s)
}

pub fn escape_basic_escapes_del_test() {
  let s = value.basic_string("a\u{007F}b")
  assert "\"a\\u007Fb\"" == value.to_toml_value(s)
}

// ---------------------------------------------------------------------------
// Multiline basic string line-ending backslash
// ---------------------------------------------------------------------------

pub fn multiline_basic_line_ending_backslash_test() {
  let assert Ok(doc) = molt.parse("x = \"\"\"line1 \\\n  line2\"\"\"\n")
  let assert Ok(v) = molt.get(doc:, path: "x")
  let assert Ok(s) = value.unwrap_string(v)
  assert s == "line1 line2"
}

pub fn multiline_basic_line_ending_backslash_tabs_test() {
  let assert Ok(doc) = molt.parse("x = \"\"\"foo\\\n\t\tbar\"\"\"\n")
  let assert Ok(v) = molt.get(doc:, path: "x")
  let assert Ok(s) = value.unwrap_string(v)
  assert s == "foobar"
}

// ---------------------------------------------------------------------------
// as_basic_string
// ---------------------------------------------------------------------------

pub fn as_basic_string_identity_test() {
  let original = value.basic_string("hello")
  let assert Ok(result) = value.as_basic_string(original)
  assert value.to_toml_value(result) == "\"hello\""
}

pub fn as_basic_string_from_literal_test() {
  let assert Ok(ls) = value.literal_string("world")
  let assert Ok(result) = value.as_basic_string(ls)
  assert value.to_toml_value(result) == "\"world\""
}

pub fn as_basic_string_from_multiline_literal_test() {
  let assert Ok(mls) = value.multiline_literal_string("abc")
  let assert Ok(result) = value.as_basic_string(mls)
  assert value.to_toml_value(result) == "\"abc\""
}

pub fn as_basic_string_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "string", ..)) =
    value.as_basic_string(value.int(1))
}

// ---------------------------------------------------------------------------
// as_multiline_basic_string
// ---------------------------------------------------------------------------

pub fn as_multiline_basic_string_identity_test() {
  let original = value.multiline_basic_string("line1\nline2")
  let assert Ok(result) = value.as_multiline_basic_string(original)
  assert value.to_toml_value(result) == "\"\"\"\nline1\nline2\"\"\""
}

pub fn as_multiline_basic_string_from_basic_test() {
  let assert Ok(result) =
    value.as_multiline_basic_string(value.basic_string("hello"))
  assert value.to_toml_value(result) == "\"\"\"\nhello\"\"\""
}

pub fn as_multiline_basic_string_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "string", ..)) =
    value.as_multiline_basic_string(value.bool(True))
}

// ---------------------------------------------------------------------------
// as_literal_string
// ---------------------------------------------------------------------------

pub fn as_literal_string_identity_test() {
  let assert Ok(original) = value.literal_string("hello")
  let assert Ok(result) = value.as_literal_string(original)
  assert value.to_toml_value(result) == "'hello'"
}

pub fn as_literal_string_from_basic_test() {
  let assert Ok(result) = value.as_literal_string(value.basic_string("clean"))
  assert value.to_toml_value(result) == "'clean'"
}

pub fn as_literal_string_rejects_single_quote_test() {
  let assert Error(error.ValueParseError(
    expected: Some("literal_string"),
    text: "it's",
  )) = value.as_literal_string(value.basic_string("it's"))
}

pub fn as_literal_string_rejects_newline_test() {
  let assert Error(error.ValueParseError(expected: Some("literal_string"), ..)) =
    value.as_literal_string(value.basic_string("line1\nline2"))
}

pub fn as_literal_string_rejects_control_char_test() {
  let assert Error(error.ValueParseError(expected: Some("literal_string"), ..)) =
    value.as_literal_string(value.basic_string("a\u{0000}b"))
}

pub fn as_literal_string_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "string", ..)) =
    value.as_literal_string(value.float(1.0))
}

// ---------------------------------------------------------------------------
// as_multiline_literal_string
// ---------------------------------------------------------------------------

pub fn as_multiline_literal_string_identity_test() {
  let assert Ok(original) = value.multiline_literal_string("line1\nline2")
  let assert Ok(result) = value.as_multiline_literal_string(original)
  assert value.to_toml_value(result) == "'''\nline1\nline2'''"
}

pub fn as_multiline_literal_string_from_basic_test() {
  let assert Ok(result) =
    value.as_multiline_literal_string(value.basic_string("hello"))
  assert value.to_toml_value(result) == "'''\nhello'''"
}

pub fn as_multiline_literal_string_allows_newline_test() {
  let assert Ok(result) =
    value.as_multiline_literal_string(value.basic_string("a\nb"))
  assert value.to_toml_value(result) == "'''\na\nb'''"
}

pub fn as_multiline_literal_string_rejects_triple_quote_test() {
  let assert Error(error.ValueParseError(
    expected: Some("multiline_literal_string"),
    ..,
  )) = value.as_multiline_literal_string(value.basic_string("end'''here"))
}

pub fn as_multiline_literal_string_rejects_control_char_test() {
  let assert Error(error.ValueParseError(
    expected: Some("multiline_literal_string"),
    ..,
  )) = value.as_multiline_literal_string(value.basic_string("a\u{0007}b"))
}

pub fn as_multiline_literal_string_type_mismatch_test() {
  let assert Error(error.TypeMismatch(expected: "string", ..)) =
    value.as_multiline_literal_string(value.int(42))
}

// ---------------------------------------------------------------------------
// type_of / unwrap / table ops (migrated from path_test, which only tests the
// path module; these exercise the value module and live here)
// ---------------------------------------------------------------------------

pub fn type_of_string_test() {
  let assert "string" = value.type_of(value.string("hello"))
}

pub fn type_of_integer_test() {
  let assert "integer" = value.type_of(value.int(42))
  let assert "integer" = value.type_of(value.hex_int(255))
}

pub fn type_of_array_test() {
  let assert "array" = value.type_of(value.array([value.int(1)]))
}

pub fn type_of_table_test() {
  let assert "inline_table" = value.type_of(value.table([#("a", value.int(1))]))
}

pub fn unwrap_string_test() {
  let assert Ok("hello") = value.unwrap_string(value.string("hello"))
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "string",
    got: "integer",
  )) = value.unwrap_string(value.int(42))
}

pub fn unwrap_string_or_test() {
  let assert "hello" = value.unwrap_string_or(value.string("hello"), "default")
  let assert "default" = value.unwrap_string_or(value.int(42), "default")
}

pub fn unwrap_int_test() {
  let assert Ok(42) = value.unwrap_int(value.int(42))
  let assert Ok(255) = value.unwrap_int(value.hex_int(255))
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "integer",
    got: "string",
  )) = value.unwrap_int(value.string("nope"))
}

pub fn unwrap_bool_test() {
  let assert Ok(True) = value.unwrap_bool(value.bool(True))
  let assert Error(error.TypeMismatch(
    path: None,
    expected: "boolean",
    got: "integer",
  )) = value.unwrap_bool(value.int(1))
}

pub fn value_get_key_test() {
  let tbl = value.table([#("name", value.string("test"))])
  let assert Ok(v) = value.table_get_key(tbl, "name")
  let assert Ok("test") = value.unwrap_string(v)
}

pub fn value_set_key_test() {
  let tbl = value.table([#("a", value.int(1))])
  let assert Ok(tbl2) = value.table_set_key(tbl, "b", value.int(2))
  let assert Ok(entries) = value.table_to_list(tbl2)
  let assert 2 = list.length(entries)
}

pub fn value_remove_key_test() {
  let tbl = value.table([#("a", value.int(1)), #("b", value.int(2))])
  let assert Ok(tbl2) = value.table_remove_key(tbl, "a")
  let assert Ok(entries) = value.table_to_list(tbl2)
  let assert 1 = list.length(entries)
}

pub fn value_rename_key_test() {
  let tbl = value.table([#("old", value.int(1)), #("other", value.int(2))])
  let assert Ok(tbl2) = value.table_rename_key(tbl, from: "old", to: "new")
  let assert Ok(v) = value.table_get_key(tbl2, "new")
  let assert Ok(1) = value.unwrap_int(v)
  let assert Error(error.ValueKeyNotFound(key: "old")) =
    value.table_get_key(tbl2, "old")
}

pub fn value_has_key_test() {
  let tbl = value.table([#("a", value.int(1)), #("b", value.int(2))])
  let assert True = value.table_has_key(tbl, "a")
  let assert True = value.table_has_key(tbl, "b")
  let assert False = value.table_has_key(tbl, "c")
}

pub fn value_has_key_non_table_test() {
  let assert False = value.table_has_key(value.int(1), "x")
}

pub fn value_keys_test() {
  let tbl = value.table([#("x", value.int(1)), #("y", value.int(2))])
  let assert Ok(["x", "y"]) = value.table_keys(tbl)
}
