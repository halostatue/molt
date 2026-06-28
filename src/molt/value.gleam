//// molt/value: TOML value manipulation
////
//// This module provides functions for working with TOML data values extracted
//// from the document. All TOML types are supported and there are some
//// convenience functions for manipulating the types.
////
//// ## `molt/value` Preserves Content, Not Representation
////
//// `Value` preserves the _content_ of the TOML values, but may change the
//// representation. Extracting a value from the document with `molt.get`,
//// unwrapping it with one of the `unwrap_*` functions, and creating a new
//// value instance to use with `molt.set` is not guaranteed to produce the
//// same representation.
////
//// - String content is preserved, but not string representation. A multiline
////   string with line-ending backslashes reads as the joined result:
////   `"abc\↵   xyz"` becomes `"abcxyz"` when accessed with `unwrap_string`.
////
//// - Integers and Floats lose leading `+` for positive values (`+99` becomes
////   `99`) and any underscore formatting (`123_456_789`).
////
//// - Structural values (tables, arrays of tables, inline tables, and arrays)
////   will lose comments, whitespace, and inline formatting.
////
//// In most circumstances, `molt/value` manipulation is unnecessary, because
//// the operations provided by `molt/ops` for use with `molt.run` all
//// preserve the document representation.
////
//// ## Function Categories
////
//// There are six categories of functions in the `molt/value` interface:
////
//// - `constructor`: functions that create a Value for the TOML value types
////   and variants described below, including constructor variants that parse
////   or classify the provided value. Some constructors perform validation on
////   the values provided and return `Result(Value, MoltError)` to ensure
////   that no invalid value is possible.
////
//// - `coercion`: functions that coerce the representation of types into
////   alternate, compatible versions. These always return `Result(Value,
////   MoltError)` since an integer value cannot be represented as a string
////   without explicit conversion (or the reverse).
////
//// - `introspection`: functions that help distinguish between TOML value
////   types and styles, or check the validity of user-constructed `Value`s.
////
//// - `value`: functions that convert most scalar `Value`s to Gleam values.
////
//// - `array`: functions that manipulate an array `Value`.
////
//// - `table`: functions that manipulate a table `Value`.
////
//// ## TOML Value Types
////
//// ### [String][toml-string] Values
////
//// There are four ways to express strings: basic, multi-line basic, literal,
//// and multi-line literal. All strings must contain only Unicode characters.
////
//// - `basic` strings allow any Unicode character may be used except characters
////   that must be escaped (`"`, `\`, and Unicode characters U+0000 to U+0008,
////   U+000A to U+001F, and U+007F).
////
////   In TOML basic strings are surrounded by single `"` characters and must
////   begin and end on a single line.
////
//// - `multiline basic` strings allow the same characters as `basic` strings,
////   except that newlines (CRLF or LF) are permitted and retained within the
////   multiline basic string (except for a newline immediately following the
////   opening delimiter). Trailing whitespace may be suppressed with the
////   line-ending `\`.
////
////   In TOML multiline basic strings are surrounded by triple `"""`
////   characters, so up to two unescaped quotation marks may be present.
////
//// - `literal` strings allow any Unicode character _except_ the literal string
////   delimiter (`'`) and control characters except for tab. Literal strings
////   must begin and end on a single line. No escapes are performed on literal
////   strings.
////
//// - `multiline literal` strings are just like `multiline basic` strings with
////   `literal` string rules applied. There are no escapes (including line
////   continuation escapes) and the delimiter is triple `'''`, allowing up to
////   two single quote marks may be present.
////
//// ### [Integer][toml-integer] Values
////
//// Integers are whole numbers. Positive numbers may be prefixed with a plus
//// sign (`+99`). Negative numbers are prefixed with a minus sign (`-99`).
//// Large numbers may have underscores between digits to enhance readability
//// (`123_456_789`). Non-negative integer values may be encoded as hexadecimal
//// (`0x7f`, `0xdead_beef`), octal (`0o755`, `0o0123_4567`), or binary
//// (`0b0110`, `0b0110_1001`).
////
//// `molt/value` will preserve hex, octal, and binary encoded integers.
////
//// ### [Float][toml-float] Values
////
//// A float consists of an integer part (which follows the same rules as
//// decimal integer values) followed by a fractional part and/or an exponent
//// part. If both a fractional part and exponent part are present, the
//// fractional part must precede the exponent part. Fractional parts are
//// separated by a decimal point and must have a digit on either side. As with
//// integers, underscores can separate digits. There are special float values
//// (treated separately by `molt/value`) also permitted:
////
//// ```toml
//// valid = [+1.0, 3.14_15, -0.01, 5e+22, 1e06, -2E-2, 7_326.626e-34]
//// invalid = [.7, 7., 3.e+20]
//// special = [inf, +inf, -inf, nan, +nan, -nan]
//// ```
////
//// ### [Boolean][toml-boolean] Values
////
//// These values are always `true` or `false` and correspond to `True` and
//// `False` Gleam values.
////
//// ### Date and Time Values
////
//// TOML supports four date and time value types, which are treated as opaque
//// strings by `molt/value`. TOML date and type value types are not wholly
//// compatible with [`gleam_time`][gleam_time] and are stored internally as the
//// [RFC3339][rfc3339] strings they are parsed from.
////
//// - [Offset Date-Time][toml-odt]: represents a specific instant with
////   a timezone offset. Seconds may be omitted in TOML 1.1 (`1979-05-27T07:32Z`
////   means the same as `1979-05-27T07:32:00Z`).
//// - [Local Date-Time][toml-ldt]: represents a date time without relationship
////   to a timezone. Seconds may be omitted in TOML 1.1.
//// - [Local Date][toml-ld]: represents a calendar day.
//// - [Local Time][toml-lt]: represents a time of day without any relation to
////   a specific day or timezone. Seconds may be omitted in TOML 1.1.
////
//// ### [Array][toml-array] Values
////
//// Arrays are inline ordered values surrounded by square brackets (`[]`) and
//// are heterogenous containing any `Value`. Newlines are allowed in the
//// document representation, but `molt/value` does not guarantee any
//// particular formatting.
////
//// ### [Table][toml-table] Values
////
//// Tables (roughly equivalent to `Dict(String, Value)`) are collections of
//// key/value pairs defined by headers on their own line (`[key]`). Until the
//// next header or end of file are `key = value` pairs. `molt/value` handles
//// tables as the key/value pairs.
////
//// ### [Inline Table][toml-inline] Values
////
//// Inline tables provide a more compact syntax for expressing tables, most
//// useful for grouped nested data that can otherwise quickly become verbose.
//// They are proper _values_ are defined within curly braces (`{}`) with commas
//// separating key/value pairs.
////
//// In TOML 1.1, tables may span multiple lines.
////
//// ### [Array of Tables][toml-AoT] Values
////
//// An array of tables (roughly equivalent to `List(Dict(String, Value))`) is
//// expressed as `[[key]]` on its own line with a table body of key/value pairs
//// immediately following.
////
//// [toml-integer]: https://toml.io/en/v1.1.0#integer
//// [toml-string]: https://toml.io/en/v1.1.0#string
//// [toml-float]: https://toml.io/en/v1.1.0#float
//// [toml-boolean]: https://toml.io/en/v1.1.0#boolean
//// [toml-odt]: https://toml.io/en/v1.1.0#offset-date-time
//// [toml-ldt]: https://toml.io/en/v1.1.0#local-date-time
//// [toml-ld]: https://toml.io/en/v1.1.0#local-date
//// [toml-lt]: https://toml.io/en/v1.1.0#local-time
//// [toml-array]: https://toml.io/en/v1.1.0#array
//// [toml-table]: https://toml.io/en/v1.1.0#table
//// [toml-inline]: https://toml.io/en/v1.1.0#inline-table
//// [toml-AoT]: https://toml.io/en/v1.1.0#array-of-tables
//// [gleam_time]: https://gleam-time.hexdocs.pm
//// [rfc3339]: https://tools.ietf.org/html/rfc3339

import gleam/bool
import gleam/dict.{type Dict}
import gleam/float as float_
import gleam/int as int_
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string as string_
import greenwood.{
  type Element, type Node, Bare, Node, NodeElement as N, Token,
  TokenElement as T,
}
import molt/cst
import molt/error.{type MoltError}
import molt/internal/classifier
import molt/internal/cst/elements
import molt/internal/parser
import molt/internal/utils
import molt/types.{type TomlKind, KeySegment}

/// Value represents any type available in TOML.
pub opaque type Value {
  // Scalar and scalar-ish (inline array, inline table) values can be used
  // in any `molt` or `molt/cst` operation.
  TomlArray(items: List(Value))
  TomlBasicString(text: Option(String), value: String)
  TomlBinaryInt(text: Option(String), value: Int)
  TomlBool(value: Bool)
  TomlFloat(text: Option(String), value: Float)
  TomlHexInt(text: Option(String), value: Int)
  TomlInfinity(sign: Sign)
  TomlInlineTable(entries: List(#(String, Value)))
  TomlInt(text: Option(String), value: Int)
  TomlLiteralString(value: String)
  TomlLocalDate(text: String)
  TomlLocalDateTime(text: String)
  TomlLocalTime(text: String)
  TomlMultilineBasicString(text: Option(String), value: String, open_nl: Bool)
  TomlMultilineLiteralString(value: String, open_nl: Bool)
  TomlNaN(sign: Sign)
  TomlOctalInt(text: Option(String), value: Int)
  TomlOffsetDateTime(text: String)

  // Structural values cannot be used with `molt/ops.Update`, but can be used
  // for other `molt` and `molt/cst` operations.
  TomlArrayOfTables(items: List(Value))
  TomlTable(entries: List(#(String, Value)))

  // Invalid values can't be used in any operations.
  TomlInvalid(text: String)
}

/// The sign to be used for a special float Value (Infinity or NaN).
///
/// |          | Infinity | NaN    |
/// | -------- | -------- | ------ |
/// | Unsigned | `inf`    | `nan`  |
/// | Positive | `+inf`   | `+nan` |
/// | Negative | `-inf`   | `-nan` |
pub type Sign {
  Unsigned
  Positive
  Negative
}

/// Create a string Value. This will attempt to guess the correct type of TOML
/// string to use, falling back to a `basic` or `multiline basic` string.
///
/// `constructor`
pub fn string(value: String) -> Value {
  // Basic strings escape `"` and `\` in both single- and multi-line form (see
  // `escape_basic_char` / `escape_multiline_basic_char`), so those are the only
  // characters for which a literal string would spare escaping. Prefer literal
  // only when it both saves escaping and is feasible: the validating literal
  // constructors reject `'`/`'''` and disallowed control characters, so an
  // infeasible literal falls back to the always-valid basic form.

  let basic_would_escape =
    string_.contains(value, "\"") || string_.contains(value, "\\")

  let has_newline = string_.contains(value, "\n")

  use <- bool.lazy_guard(has_newline && basic_would_escape, return: fn() {
    multiline_literal_string(value)
    |> result.lazy_unwrap(or: fn() { multiline_basic_string(value) })
  })

  use <- bool.guard(has_newline, return: multiline_basic_string(value))

  use <- bool.lazy_guard(basic_would_escape, return: fn() {
    literal_string(value)
    |> result.lazy_unwrap(or: fn() { basic_string(value) })
  })
  basic_string(value)
}

/// Creates a basic string Value. TOML basic strings process escape characters
/// and bare newlines are not permitted.
///
/// `constructor`
pub fn basic_string(value: String) -> Value {
  TomlBasicString(text: None, value:)
}

/// Creates a multiline basic string Value. TOML basic strings process escape
/// characters. Bare newlines are permitted.
///
/// `constructor`
pub fn multiline_basic_string(value: String) -> Value {
  TomlMultilineBasicString(text: None, value:, open_nl: True)
}

/// Creates a literal string Value. TOML literal strings do not process escape
/// characters and bare newlines are not permitted.
///
/// Returns a `ValueParseError` if `value` contains `'`, a newline, a carriage
/// return, or any control character other than tab.
///
/// `constructor`
pub fn literal_string(value: String) -> Result(Value, MoltError) {
  use <- bool.guard(
    has_disallowed_literal_char(value),
    return: Error(error.ValueParseError(
      expected: Some("literal_string"),
      text: value,
    )),
  )
  Ok(TomlLiteralString(value:))
}

/// Creates a multiline literal string Value. TOML literal strings do not
/// process escape characters. Bare newlines are permitted.
///
/// Returns a `ValueParseError` if `value` contains `'''` or any control
/// character other than tab, LF, or CR.
///
/// `constructor`
pub fn multiline_literal_string(value: String) -> Result(Value, MoltError) {
  use <- bool.guard(
    has_disallowed_multiline_literal_char(value),
    return: Error(error.ValueParseError(
      expected: Some("multiline_literal_string"),
      text: value,
    )),
  )
  Ok(TomlMultilineLiteralString(value:, open_nl: True))
}

/// Create an integer Value.
///
/// `constructor`
pub fn int(value: Int) -> Value {
  TomlInt(text: None, value:)
}

/// Create a integer Value encoded as hex (`0xff`).
///
/// `constructor`
pub fn hex_int(value: Int) -> Value {
  TomlHexInt(text: None, value:)
}

/// Create a integer Value encoded as octal (`0o67`).
///
/// `constructor`
pub fn octal_int(value: Int) -> Value {
  TomlOctalInt(text: None, value:)
}

/// Create a integer Value encoded as binary (`0b1001`).
///
/// `constructor`
pub fn binary_int(value: Int) -> Value {
  TomlBinaryInt(text: None, value:)
}

/// Create a float Value.
///
/// `constructor`
pub fn float(value: Float) -> Value {
  TomlFloat(text: None, value:)
}

/// Create a unsigned infinity Value.
///
/// `constructor`
pub fn infinity() -> Value {
  TomlInfinity(sign: Unsigned)
}

/// Create a signed infinity Value.
///
/// `constructor`
pub fn signed_infinity(sign: Sign) -> Value {
  TomlInfinity(sign:)
}

/// Create a unsigned NaN Value.
///
/// `constructor`
pub fn nan() -> Value {
  TomlNaN(sign: Unsigned)
}

/// Create a signed NaN Value.
///
/// `constructor`
pub fn signed_nan(sign: Sign) -> Value {
  TomlNaN(sign:)
}

/// Create a boolean Value.
///
/// `constructor`
pub fn bool(value: Bool) -> Value {
  TomlBool(value:)
}

/// Creates a date-time, date, or time Value from an RFC3339-compatible `text`
/// value. See [Date and Time Values](#date-and-time-values).
///
/// Returns a `ValueParseError` if the `text` cannot be parsed.
///
/// `constructor`
pub fn datetime(text: String) -> Result(Value, MoltError) {
  case classifier.match_datetime(text) {
    Some(types.OffsetDateTime) -> Ok(TomlOffsetDateTime(text:))
    Some(types.LocalDateTime) -> Ok(TomlLocalDateTime(text:))
    Some(types.LocalDate) -> Ok(TomlLocalDate(text:))
    Some(types.LocalTime) -> Ok(TomlLocalTime(text:))
    _ ->
      Error(error.ValueParseError(
        expected: Some(
          "offset_datetime, local_datetime, local_date, or local_time",
        ),
        text:,
      ))
  }
}

/// Creates an offset date-time Value.
///
/// Returns a `ValueParseError` if the `text` cannot be parsed as an offset
/// date-time value.
///
/// `constructor`
pub fn offset_datetime(text: String) -> Result(Value, MoltError) {
  case classifier.match_datetime(text) {
    Some(types.OffsetDateTime) -> Ok(TomlOffsetDateTime(text:))
    _ -> Error(error.ValueParseError(expected: Some("offset_datetime"), text:))
  }
}

/// Creates a local date-time Value.
///
/// Returns a `ValueParseError` if the `text` cannot be parsed as a local
/// date-time value.
///
/// `constructor`
pub fn local_datetime(text: String) -> Result(Value, MoltError) {
  case classifier.match_datetime(text) {
    Some(types.LocalDateTime) -> Ok(TomlLocalDateTime(text:))
    _ -> Error(error.ValueParseError(expected: Some("local_datetime"), text:))
  }
}

/// Creates a local date Value.
///
/// Returns a `ValueParseError` if the `text` cannot be parsed as a local date
/// value.
///
/// `constructor`
pub fn local_date(text: String) -> Result(Value, MoltError) {
  case classifier.match_datetime(text) {
    Some(types.LocalDate) -> Ok(TomlLocalDate(text:))
    _ -> Error(error.ValueParseError(expected: Some("local_date"), text:))
  }
}

/// Creates a local time Value.
///
/// Returns a `ValueParseError` if the `text` cannot be parsed as a local time
/// value.
///
/// `constructor`
pub fn local_time(text: String) -> Result(Value, MoltError) {
  case classifier.match_datetime(text) {
    Some(types.LocalTime) -> Ok(TomlLocalTime(text:))
    _ -> Error(error.ValueParseError(expected: Some("local_time"), text:))
  }
}

/// Create an inline table Value from the entries.
///
/// `constructor`
pub fn table(entries: List(#(String, Value))) -> Value {
  TomlInlineTable(entries:)
}

/// Create an inline table Value from a Dict.
///
/// The order of keys in the inline table is non-deterministic but fixed at time
/// of creation.
///
/// `constructor`
pub fn table_from_dict(entries: Dict(String, Value)) -> Value {
  TomlInlineTable(entries: dict.to_list(entries))
}

/// Create an array Value.
///
/// `constructor`
pub fn array(items: List(Value)) -> Value {
  TomlArray(items:)
}

/// Coerces a table-like value to an inline table.
///
/// Returns a `TypeMismatch` error if the value is not table-shaped.
///
/// `coercion`
pub fn as_inline_table(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlInlineTable(_) as self -> Ok(self)
    TomlTable(entries:) -> Ok(TomlInlineTable(entries:))
    _ -> Error(type_mismatch(value, "table or inline_table"))
  }
}

/// Coerces a table-like value to a table with a section header.
///
/// Returns a `TypeMismatch` error if the value is not table-shaped.
///
/// `coercion`
pub fn as_section_table(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlTable(_) as self -> Ok(self)
    TomlInlineTable(entries:) -> Ok(TomlTable(entries:))
    _ -> Error(type_mismatch(value, "table or inline_table"))
  }
}

/// Coerces an array-like value to an array.
///
/// Returns a `TypeMismatch` error if the value is not array-shaped.
///
/// When coercing an array of tables to an array, `as_array` will coerce the
/// items with `as_inline_table`, returning an `InvalidOperation` if any item
/// fails to convert.
///
/// `coercion`
pub fn as_array(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlArray(_) as self -> Ok(self)
    TomlArrayOfTables(items:) ->
      list.try_map(items, as_inline_table)
      |> result.map(TomlArray(items: _))
      |> result.replace_error(error.InvalidOperation(
        operation: "as_array",
        reason: Some("array_of_tables contains one or more non-table items"),
      ))
    _ -> Error(type_mismatch(value, "array or array_of_tables"))
  }
}

/// Coerces an array-like value containing table-like values to an array of
/// tables.
///
/// Returns a `TypeMismatch` error if the value is not array-shaped. If any
/// value in the provided array is not table-like, an `InvalidOperation` error
/// will be returned.
///
/// `coercion`
pub fn as_array_of_tables(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlArrayOfTables(_) as self -> Ok(self)
    TomlArray(items:) ->
      list.try_map(items, as_section_table)
      |> result.map(TomlArrayOfTables(items: _))
      |> result.replace_error(error.InvalidOperation(
        operation: "as_array_of_tables",
        reason: Some("array contains one or more non-table items"),
      ))
    _ -> Error(type_mismatch(value, "array or array_of_tables"))
  }
}

/// Coerces an integer variant to decimal representation.
///
/// Returns a `TypeMismatch` error if the value is not an integer.
///
/// `coercion`
pub fn as_decimal_int(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlInt(..) as self -> Ok(self)
    TomlHexInt(value:, ..)
    | TomlOctalInt(value:, ..)
    | TomlBinaryInt(value:, ..) -> Ok(TomlInt(value:, text: None))
    _ -> Error(type_mismatch(value, "integer"))
  }
}

/// Coerces an integer variant to hex representation.
///
/// Returns a `TypeMismatch` error if the value is not an integer.
///
/// `coercion`
pub fn as_hex_int(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlHexInt(..) as self -> Ok(self)
    TomlInt(value:, ..)
    | TomlOctalInt(value:, ..)
    | TomlBinaryInt(value:, ..) -> Ok(TomlHexInt(value:, text: None))
    _ -> Error(type_mismatch(value, "integer"))
  }
}

/// Coerces an integer variant to octal representation.
///
/// Returns a `TypeMismatch` error if the value is not an integer.
///
/// `coercion`
pub fn as_octal_int(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlOctalInt(..) as self -> Ok(self)
    TomlInt(value:, ..) | TomlHexInt(value:, ..) | TomlBinaryInt(value:, ..) ->
      Ok(TomlOctalInt(value:, text: None))
    _ -> Error(type_mismatch(value, "integer"))
  }
}

/// Coerces an integer variant to binary representation.
///
/// Returns a `TypeMismatch` error if the value is not an integer.
///
/// `coercion`
pub fn as_binary_int(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlBinaryInt(..) as self -> Ok(self)
    TomlInt(value:, ..) | TomlHexInt(value:, ..) | TomlOctalInt(value:, ..) ->
      Ok(TomlBinaryInt(value:, text: None))
    _ -> Error(type_mismatch(value, "integer"))
  }
}

/// Coerces a string to a basic (double-quoted, `"`) string.
///
/// Returns a `TypeMismatch` error if the value is not a string.
///
/// `coercion`
pub fn as_basic_string(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlBasicString(..) as self -> Ok(self)
    TomlMultilineBasicString(value:, ..)
    | TomlLiteralString(value:)
    | TomlMultilineLiteralString(value:, ..) ->
      Ok(TomlBasicString(text: None, value:))
    _ -> Error(type_mismatch(value, "string"))
  }
}

/// Coerces a string to a multiline basic (triple-double-quoted, `"""`) string.
///
/// Returns a `TypeMismatch` error if the value is not a string.
///
/// `coercion`
pub fn as_multiline_basic_string(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlMultilineBasicString(..) as self -> Ok(self)
    TomlBasicString(value:, ..)
    | TomlLiteralString(value:)
    | TomlMultilineLiteralString(value:, ..) ->
      Ok(TomlMultilineBasicString(text: None, value:, open_nl: True))
    _ -> Error(type_mismatch(value, "string"))
  }
}

/// Coerces a string to a literal (single-quoted, `'`) string.
///
/// Returns a `TypeMismatch` error if the value is not a string. Returns
/// a `ValueParseError` if the content contains characters that cannot appear in
/// a single-quoted literal string: `'`, newlines, or control characters other
/// than tab.
///
/// `coercion`
pub fn as_literal_string(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlLiteralString(..) as self -> Ok(self)
    TomlBasicString(value:, ..)
    | TomlMultilineBasicString(value:, ..)
    | TomlMultilineLiteralString(value:, ..) -> {
      use <- bool.guard(
        has_disallowed_literal_char(value),
        return: Error(error.ValueParseError(
          expected: Some("literal_string"),
          text: value,
        )),
      )
      Ok(TomlLiteralString(value:))
    }
    _ -> Error(type_mismatch(value, "string"))
  }
}

/// Coerces a string to a multiline literal (triple-single-quoted, `'''`)
/// string.
///
/// Returns a `TypeMismatch` error if the value is not a string. Returns
/// a `ValueParseError` if the content contains `'''` or control characters not
/// permitted in multiline literal strings (only tab, LF, and CR are allowed
/// alongside other Unicode).
///
/// `coercion`
pub fn as_multiline_literal_string(value: Value) -> Result(Value, MoltError) {
  case value {
    TomlMultilineLiteralString(..) as self -> Ok(self)
    TomlBasicString(value:, ..)
    | TomlMultilineBasicString(value:, ..)
    | TomlLiteralString(value:) -> {
      use <- bool.guard(
        has_disallowed_multiline_literal_char(value),
        return: Error(error.ValueParseError(
          expected: Some("multiline_literal_string"),
          text: value,
        )),
      )
      Ok(TomlMultilineLiteralString(value:, open_nl: True))
    }
    _ -> Error(type_mismatch(value, "string"))
  }
}

/// Returns the TOML type name for a Value.
///
/// Strings and integers have attached styles that can be retrieved with
/// `string_style` and `int_style`.
///
/// `introspection`
pub fn type_of(value: Value) -> String {
  case value {
    TomlBasicString(..)
    | TomlMultilineBasicString(..)
    | TomlLiteralString(..)
    | TomlMultilineLiteralString(..) -> "string"
    TomlInt(..) | TomlHexInt(..) | TomlOctalInt(..) | TomlBinaryInt(..) ->
      "integer"
    TomlFloat(..) -> "float"
    TomlInfinity(..) -> "infinity"
    TomlNaN(..) -> "nan"
    TomlBool(..) -> "boolean"
    TomlArray(..) -> "array"
    TomlArrayOfTables(..) -> "array_of_tables"
    TomlTable(..) -> "table"
    TomlInlineTable(..) -> "inline_table"
    TomlOffsetDateTime(..) -> "offset_datetime"
    TomlLocalDateTime(..) -> "local_datetime"
    TomlLocalDate(..) -> "local_date"
    TomlLocalTime(..) -> "local_time"
    TomlInvalid(..) -> "invalid"
  }
}

/// Returns a debug string representation of a Value.
///
/// `introspection`
pub fn inspect(value: Value) -> String {
  type_of(value) <> "(" <> to_toml_value(value) <> ")"
}

/// Returns the raw text of a `TomlInvalid` value, or empty string otherwise.
///
/// `introspection`
pub fn invalid_text(value: Value) -> String {
  case value {
    TomlInvalid(text:) -> text
    _ -> ""
  }
}

/// Returns the style of string Value, or None if not a string.
///
/// `introspection`
pub fn string_style(value: Value) -> Option(String) {
  case value {
    TomlBasicString(..) -> Some("basic")
    TomlMultilineBasicString(..) -> Some("multiline_basic")
    TomlLiteralString(..) -> Some("literal")
    TomlMultilineLiteralString(..) -> Some("multiline_literal")
    _ -> None
  }
}

/// Returns the style of integer Value, or None if not an integer.
///
/// `introspection`
pub fn int_style(value: Value) -> Option(String) {
  case value {
    TomlInt(..) -> Some("decimal")
    TomlHexInt(..) -> Some("hex")
    TomlOctalInt(..) -> Some("octal")
    TomlBinaryInt(..) -> Some("binary")
    _ -> None
  }
}

/// Returns True if a Value's text is syntactically valid TOML.
///
/// Values created using the constructor functions (including `parse_value`) are
/// guaranteed to be valid, but values retrieved from a TOML document with
/// `molt/cst` functions may be invalid.
///
/// `introspection`
pub fn is_valid(value: Value) -> Bool {
  case value {
    TomlInvalid(..) -> False
    _ ->
      to_toml(key: "_v", value:)
      |> result.map(parser.parse)
      |> result.is_ok
  }
}

/// Unwraps the string Value or returns a `TypeMismatch` error.
///
/// `value`
pub fn unwrap_string(value: Value) -> Result(String, MoltError) {
  case value {
    TomlBasicString(value:, ..)
    | TomlMultilineBasicString(value:, ..)
    | TomlLiteralString(value:)
    | TomlMultilineLiteralString(value:, ..) -> Ok(value)
    _ -> Error(type_mismatch(value, "string"))
  }
}

/// Unwraps the string Value or returns the default.
///
/// `value`
pub fn unwrap_string_or(value value: Value, default default: String) -> String {
  unwrap_string(value)
  |> result.unwrap(default)
}

/// Unwraps the integer Value or returns a `TypeMismatch` error.
///
/// `value`
pub fn unwrap_int(value: Value) -> Result(Int, MoltError) {
  case value {
    TomlInt(value:, ..)
    | TomlHexInt(value:, ..)
    | TomlOctalInt(value:, ..)
    | TomlBinaryInt(value:, ..) -> Ok(value)
    _ -> Error(type_mismatch(value, "integer"))
  }
}

/// Unwraps the integer Value or returns the default.
///
/// `value`
pub fn unwrap_int_or(value value: Value, default default: Int) -> Int {
  unwrap_int(value)
  |> result.unwrap(default)
}

/// Unwraps the float Value or returns a `TypeMismatch` error.
///
/// `value`
pub fn unwrap_float(value: Value) -> Result(Float, MoltError) {
  case value {
    TomlFloat(value:, ..) -> Ok(value)
    _ -> Error(type_mismatch(value, "float"))
  }
}

/// Unwraps the float Value or returns the default.
///
/// `value`
pub fn unwrap_float_or(value value: Value, default default: Float) -> Float {
  unwrap_float(value)
  |> result.unwrap(default)
}

/// Unwraps the boolean Value or returns a `TypeMismatch` error.
///
/// `value`
pub fn unwrap_bool(value: Value) -> Result(Bool, MoltError) {
  case value {
    TomlBool(value:) -> Ok(value)
    _ -> Error(type_mismatch(value, "boolean"))
  }
}

/// Unwraps the boolean Value or returns the default.
///
/// `value`
pub fn unwrap_bool_or(value value: Value, default default: Bool) -> Bool {
  unwrap_bool(value)
  |> result.unwrap(default)
}

/// Unwraps the offset date-time, local date-time, local date, or local time
/// Value as the constructed RFC3339 string or returns a `TypeMismatch` error.
///
/// `value`
pub fn unwrap_datetime(value: Value) -> Result(String, MoltError) {
  case value {
    TomlLocalDate(text:)
    | TomlLocalDateTime(text:)
    | TomlLocalTime(text:)
    | TomlOffsetDateTime(text:) -> Ok(text)
    _ ->
      Error(type_mismatch(
        value,
        "offset_datetime, local_datetime, local_date, or local_time",
      ))
  }
}

/// Get the element at index from an array or array of tables Value.
///
/// Negative indices count from the end of the array.
///
/// `array`
pub fn array_get_at(
  value value: Value,
  index index: Int,
) -> Result(Value, MoltError) {
  use items <- require_array(value)

  let length = list.length(items)
  let resolved = utils.resolve_index(index, length)

  use <- bool.guard(
    resolved < 0 || resolved >= length,
    return: Error(error.ValueIndexOutOfRange(index:, length:)),
  )

  utils.list_at(items, resolved)
  |> result.replace_error(error.ValueIndexOutOfRange(index:, length:))
}

/// Replace the element at index in an array Value.
///
/// Negative indices count from the end of the array.
///
/// `array`
pub fn array_replace_at(
  value value: Value,
  index index: Int,
  new new: Value,
) -> Result(Value, MoltError) {
  use items <- require_array(value)
  let len = list.length(items)
  let resolved = utils.resolve_index(index, len)

  use <- bool.guard(
    resolved < 0 || resolved >= len,
    return: Error(error.ValueIndexOutOfRange(index:, length: len)),
  )

  let new_items =
    list.index_map(items, fn(item, i) {
      case i == resolved {
        True -> new
        False -> item
      }
    })
  Ok(rebuild_array(value, new_items))
}

/// Remove the element at index from the array Value.
///
/// Negative indices count from the end of the array.
///
/// `array`
pub fn array_remove_at(
  value value: Value,
  index index: Int,
) -> Result(Value, MoltError) {
  use items <- require_array(value)
  let len = list.length(items)
  let resolved = utils.resolve_index(index, len)

  use <- bool.guard(
    resolved < 0 || resolved >= len,
    return: Error(error.ValueIndexOutOfRange(index:, length: len)),
  )

  let new_items =
    list.index_fold(items, [], fn(acc, item, i) {
      case i == resolved {
        True -> acc
        False -> [item, ..acc]
      }
    })
    |> list.reverse
  Ok(rebuild_array(value, new_items))
}

/// Insert an element before the given index. Negative indices count from end.
///
/// `array`
pub fn array_insert_at(
  value value: Value,
  index index: Int,
  new new: Value,
) -> Result(Value, MoltError) {
  use items <- require_array(value)
  let len = list.length(items)
  let resolved = utils.resolve_index(index, len)

  use <- bool.guard(
    resolved < 0 || resolved > len,
    return: Error(error.ValueIndexOutOfRange(index:, length: len)),
  )

  let #(before, after) = list.split(items, resolved)
  let new_items = list.append(before, [new, ..after])
  Ok(rebuild_array(value, new_items))
}

/// Append an element to the end of an array.
///
/// `array`
pub fn array_append(
  value value: Value,
  new new: Value,
) -> Result(Value, MoltError) {
  use items <- require_array(value)
  Ok(rebuild_array(value, list.append(items, [new])))
}

/// Extract the items list from an array value.
///
/// `array`
pub fn array_to_list(value: Value) -> Result(List(Value), MoltError) {
  use items <- require_array(value)
  Ok(items)
}

/// Returns the size of an array. Returns `None` if the value provided is not an
/// array.
///
/// `array`
pub fn array_length(value: Value) -> Option(Int) {
  case value {
    TomlArray(items:) | TomlArrayOfTables(items:) -> Some(list.length(items))
    _ -> None
  }
}

/// Get the value for a key in a table.
///
/// `table`
pub fn table_get_key(
  value value: Value,
  key key: String,
) -> Result(Value, MoltError) {
  use entries <- require_table(value)
  case list.find(entries, fn(entry) { entry.0 == key }) {
    Ok(#(_, v)) -> Ok(v)
    Error(_) -> Error(error.ValueKeyNotFound(key:))
  }
}

/// Check if a key exists in a table.
///
/// `table`
pub fn table_has_key(value value: Value, key key: String) -> Bool {
  case value {
    TomlInlineTable(entries:) | TomlTable(entries:) ->
      list.any(entries, fn(entry) { entry.0 == key })
    _ -> False
  }
}

/// Get the list of key names from a table.
///
/// `table`
pub fn table_keys(value: Value) -> Result(List(String), MoltError) {
  use entries <- require_table(value)
  Ok(list.map(entries, fn(entry) { entry.0 }))
}

/// Set or replace a key in a table. Appends if key doesn't exist.
///
/// `table`
pub fn table_set_key(
  value value: Value,
  key key: String,
  new new: Value,
) -> Result(Value, MoltError) {
  use entries <- require_table(value)
  let new_entries = case list.any(entries, fn(entry) { entry.0 == key }) {
    True ->
      list.map(entries, fn(entry) {
        case entry.0 == key {
          True -> #(key, new)
          False -> entry
        }
      })
    False -> list.append(entries, [#(key, new)])
  }
  Ok(rebuild_table(value, new_entries))
}

/// Remove a key from a table.
///
/// `table`
pub fn table_remove_key(
  value value: Value,
  key key: String,
) -> Result(Value, MoltError) {
  use entries <- require_table(value)
  let new_entries = list.filter(entries, fn(entry) { entry.0 != key })
  Ok(rebuild_table(value, new_entries))
}

/// Rename a key in a table. Errors if the key doesn't exist.
///
/// `table`
pub fn table_rename_key(
  value value: Value,
  from from: String,
  to to: String,
) -> Result(Value, MoltError) {
  use entries <- require_table(value)

  use <- bool.guard(
    !list.any(entries, fn(entry) { entry.0 == from }),
    return: Error(error.ValueKeyNotFound(key: from)),
  )

  let new_entries =
    list.map(entries, fn(entry) {
      case entry.0 == from {
        True -> #(to, entry.1)
        False -> entry
      }
    })
  Ok(rebuild_table(value, new_entries))
}

/// Extract the entries list from a table value.
///
/// `table`
pub fn table_to_list(
  value: Value,
) -> Result(List(#(String, Value)), MoltError) {
  use entries <- require_table(value)
  Ok(entries)
}

/// Extract a Dict from a table value. Key order is lost.
///
/// `table`
pub fn table_to_dict(value: Value) -> Result(Dict(String, Value), MoltError) {
  use entries <- require_table(value)
  Ok(dict.from_list(entries))
}

@internal
pub fn to_toml(
  key key: String,
  value value: Value,
) -> Result(String, MoltError) {
  let key = utils.quote_key(key)

  case value {
    TomlTable(entries:) ->
      Ok("[" <> key <> "]\n" <> serialize_table_body(entries) <> "\n")

    TomlArrayOfTables(items:) -> {
      list.try_map(items, fn(entry) {
        case entry {
          TomlInlineTable(entries:) | TomlTable(entries:) ->
            Ok("[[" <> key <> "]]\n" <> serialize_table_body(entries) <> "\n")
          _ ->
            Error(error.TypeMismatch(
              path: None,
              expected: "table",
              got: "non-table item in array table",
            ))
        }
      })
      |> result.map(string_.join(_, "\n"))
    }
    _ -> Ok(key <> " = " <> to_toml_value(value))
  }
}

@internal
pub fn to_toml_value(value: Value) -> String {
  case value {
    TomlBasicString(text: Some(t), ..)
    | TomlMultilineBasicString(text: Some(t), ..) -> t
    TomlBasicString(text: None, value:) -> "\"" <> escape_basic(value) <> "\""
    TomlMultilineBasicString(text: None, value:, open_nl: True) ->
      "\"\"\"\n" <> escape_multiline_basic(value) <> "\"\"\""
    TomlMultilineBasicString(text: None, value:, open_nl: False) ->
      "\"\"\"" <> escape_multiline_basic(value) <> "\"\"\""
    TomlLiteralString(value:) -> "'" <> value <> "'"
    TomlMultilineLiteralString(value:, open_nl: True) ->
      "'''\n" <> value <> "'''"
    TomlMultilineLiteralString(value:, open_nl: False) ->
      "'''" <> value <> "'''"
    TomlInt(text: Some(t), ..) -> t
    TomlInt(text: None, value:) -> int_.to_string(value)
    TomlHexInt(text: Some(t), ..) -> t
    TomlHexInt(text: None, value:) -> "0x" <> int_.to_base16(value)
    TomlOctalInt(text: Some(t), ..) -> t
    TomlOctalInt(text: None, value:) -> "0o" <> int_.to_base8(value)
    TomlBinaryInt(text: Some(t), ..) -> t
    TomlBinaryInt(text: None, value:) -> "0b" <> int_.to_base2(value)
    TomlFloat(text: Some(t), ..) -> t
    TomlFloat(text: None, value:) -> float_.to_string(value)
    TomlInfinity(sign: Unsigned) -> "inf"
    TomlInfinity(sign: Positive) -> "+inf"
    TomlInfinity(sign: Negative) -> "-inf"
    TomlNaN(sign: Unsigned) -> "nan"
    TomlNaN(sign: Positive) -> "+nan"
    TomlNaN(sign: Negative) -> "-nan"
    TomlBool(value: True) -> "true"
    TomlBool(value: False) -> "false"
    TomlOffsetDateTime(text:) -> text
    TomlLocalDateTime(text:) -> text
    TomlLocalDate(text:) -> text
    TomlLocalTime(text:) -> text
    TomlArray(items:) | TomlArrayOfTables(items:) -> serialize_array(items)
    TomlTable(entries:) -> serialize_table_body(entries)
    TomlInlineTable(entries:) -> serialize_inline_table(entries)
    TomlInvalid(text:) -> text
  }
}

/// Produce a syntax tree representation of the value suitable for use with
/// `cst.set_kv_value`.
pub fn to_cst(value: Value) -> Element(TomlKind) {
  case value {
    TomlBasicString(text: Some(t), ..) ->
      T(Token(kind: types.BasicString, text: strip_delims(t, 1)))
    TomlBasicString(text: None, value:) ->
      T(Token(kind: types.BasicString, text: escape_basic(value)))
    TomlMultilineBasicString(text: Some(t), ..) -> {
      let raw = strip_delims(t, 3)
      let #(kind, content) = case raw {
        "\r\n" <> rest -> #(types.MultilineBasicStringNl, rest)
        "\n" <> rest -> #(types.MultilineBasicStringNl, rest)
        _ -> #(types.MultilineBasicString, raw)
      }
      T(Token(kind:, text: content))
    }
    TomlMultilineBasicString(text: None, value:, open_nl: True) ->
      T(Token(
        kind: types.MultilineBasicStringNl,
        text: escape_multiline_basic(value),
      ))
    TomlMultilineBasicString(text: None, value:, open_nl: False) ->
      T(Token(
        kind: types.MultilineBasicString,
        text: escape_multiline_basic(value),
      ))
    TomlLiteralString(value:) ->
      T(Token(kind: types.LiteralString, text: value))
    TomlMultilineLiteralString(value:, open_nl: True) ->
      T(Token(kind: types.MultilineLiteralStringNl, text: value))
    TomlMultilineLiteralString(value:, open_nl: False) ->
      T(Token(kind: types.MultilineLiteralString, text: value))
    TomlInt(text: Some(t), ..) -> T(Token(kind: types.Integer, text: t))
    TomlInt(text: None, value:) ->
      T(Token(kind: types.Integer, text: int_.to_string(value)))
    TomlHexInt(text: Some(t), ..) -> T(Token(kind: types.HexInteger, text: t))
    TomlHexInt(text: None, value:) ->
      T(Token(kind: types.HexInteger, text: "0x" <> int_.to_base16(value)))
    TomlOctalInt(text: Some(t), ..) ->
      T(Token(kind: types.OctalInteger, text: t))
    TomlOctalInt(text: None, value:) ->
      T(Token(kind: types.OctalInteger, text: "0o" <> int_.to_base8(value)))
    TomlBinaryInt(text: Some(t), ..) ->
      T(Token(kind: types.BinaryInteger, text: t))
    TomlBinaryInt(text: None, value:) ->
      T(Token(kind: types.BinaryInteger, text: "0b" <> int_.to_base2(value)))
    TomlFloat(text: Some(t), ..) -> T(Token(kind: types.Float, text: t))
    TomlFloat(text: None, value:) ->
      T(Token(kind: types.Float, text: float_.to_string(value)))
    TomlInfinity(sign: Unsigned) -> T(Token(kind: types.Inf, text: ""))
    TomlInfinity(sign: Positive) -> T(Token(kind: types.PosInf, text: ""))
    TomlInfinity(sign: Negative) -> T(Token(kind: types.NegInf, text: ""))
    TomlNaN(sign: Unsigned) -> T(Token(kind: types.NaN, text: ""))
    TomlNaN(sign: Positive) -> T(Token(kind: types.PosNaN, text: ""))
    TomlNaN(sign: Negative) -> T(Token(kind: types.NegNaN, text: ""))
    TomlBool(value: True) -> T(Token(kind: types.BoolTrue, text: ""))
    TomlBool(value: False) -> T(Token(kind: types.BoolFalse, text: ""))
    TomlOffsetDateTime(text:) -> T(Token(kind: types.OffsetDateTime, text:))
    TomlLocalDateTime(text:) -> T(Token(kind: types.LocalDateTime, text:))
    TomlLocalDate(text:) -> T(Token(kind: types.LocalDate, text:))
    TomlLocalTime(text:) -> T(Token(kind: types.LocalTime, text:))
    TomlArray(items:) -> N(build_array_cst(items))
    TomlInlineTable(entries:) -> N(build_inline_table_cst(entries))
    TomlArrayOfTables(items:) -> N(build_array_cst(items))
    TomlTable(entries:) -> N(build_inline_table_cst(entries))
    TomlInvalid(text:) -> T(Token(kind: types.InvalidValue, text:))
  }
}

/// Parse a value as a Value or return an error if the value cannot be
/// resolved.
///
/// `constructor`
pub fn parse_value(text: String) -> Result(Value, MoltError) {
  let doc_text = "v = " <> string_.trim(text) <> "\n"

  use root <- result.try(
    parser.parse(doc_text)
    |> result.replace_error(error.ValueParseError(expected: None, text:)),
  )

  case cst.get(node: root, path: [KeySegment("v")]) {
    Ok(kv) ->
      case from_cst(kv) {
        TomlInvalid(text:) ->
          Error(error.ValueParseError(expected: None, text:))
        value -> Ok(value)
      }
    Error(_) -> Error(error.ValueParseError(expected: None, text:))
  }
}

@internal
pub fn from_table_entries(entries: List(#(String, Value))) -> Value {
  TomlTable(entries:)
}

@internal
pub fn from_array_of_tables(items: List(Value)) -> Result(Value, MoltError) {
  use <- bool.guard(
    list.all(items, fn(v) {
      case v {
        TomlTable(_) -> True
        _ -> False
      }
    }),
    return: Ok(TomlArrayOfTables(items:)),
  )

  Error(error.TypeMismatch(
    path: None,
    expected: "table",
    got: "non-table item in array table",
  ))
}

@internal
pub fn from_cst(kv: Node(TomlKind)) -> Value {
  case kv.kind {
    types.ArrayElement ->
      elements.find_first_value(kv.children)
      |> option.map(element_to_value)
      |> option.unwrap(invalid(""))
    _ ->
      elements.find_first_value(elements.value_tokens(kv.children))
      |> option.map(element_to_value)
      |> option.unwrap(invalid(""))
  }
}

fn build_array_cst(items: List(Value)) -> Node(TomlKind) {
  let children =
    [T(Token(kind: types.LeftBracket, text: ""))]
    |> list.append(build_array_elements(items, []))
    |> list.append([
      T(Token(kind: types.RightBracket, text: "")),
    ])
  greenwood.node(types.Array, children)
}

fn build_array_elements(
  items: List(Value),
  acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case items {
    [] -> list.reverse(acc)
    [item] -> {
      let el =
        Node(kind: types.ArrayElement, children: [to_cst(item)], trivia: Bare)
      list.reverse([N(el), ..acc])
    }
    [item, ..rest] -> {
      let el =
        Node(
          kind: types.ArrayElement,
          children: [
            to_cst(item),
            T(Token(kind: types.Comma, text: "")),
            T(Token(kind: types.Whitespace, text: " ")),
          ],
          trivia: Bare,
        )
      build_array_elements(rest, [N(el), ..acc])
    }
  }
}

fn build_inline_table_cst(entries: List(#(String, Value))) -> Node(TomlKind) {
  let children =
    [T(Token(kind: types.LeftBrace, text: ""))]
    |> list.append(build_inline_table_entries(entries, []))
    |> list.append([
      T(Token(kind: types.RightBrace, text: "")),
    ])
  greenwood.node(types.InlineTable, children)
}

fn build_inline_table_entries(
  entries: List(#(String, Value)),
  acc: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case entries {
    [] -> list.reverse(acc)
    [#(key, val)] -> {
      let kv =
        Node(
          kind: types.KeyValue,
          children: [
            T(Token(kind: types.BareKey, text: utils.quote_key(key))),
            T(Token(kind: types.Whitespace, text: " ")),
            T(Token(kind: types.Equals, text: "")),
            T(Token(kind: types.Whitespace, text: " ")),
            to_cst(val),
          ],
          trivia: Bare,
        )
      list.reverse([N(kv), ..acc])
    }
    [#(key, val), ..rest] -> {
      let kv =
        Node(
          kind: types.KeyValue,
          children: [
            T(Token(kind: types.BareKey, text: utils.quote_key(key))),
            T(Token(kind: types.Whitespace, text: " ")),
            T(Token(kind: types.Equals, text: "")),
            T(Token(kind: types.Whitespace, text: " ")),
            to_cst(val),
            T(Token(kind: types.Comma, text: "")),
            T(Token(kind: types.Whitespace, text: " ")),
          ],
          trivia: Bare,
        )
      build_inline_table_entries(rest, [N(kv), ..acc])
    }
  }
}

fn strip_delims(text: String, n: Int) -> String {
  string_.drop_start(text, n) |> string_.drop_end(n)
}

fn serialize_array(items: List(Value)) -> String {
  let inner = list.map(items, to_toml_value) |> string_.join(", ")
  "[" <> inner <> "]"
}

fn escape_basic(value: String) -> String {
  value
  |> string_.to_graphemes
  |> list.map(escape_basic_char)
  |> string_.join("")
}

fn escape_multiline_basic(value: String) -> String {
  value
  |> string_.to_graphemes
  |> list.map(escape_multiline_basic_char)
  |> string_.join("")
}

fn escape_basic_char(char: String) -> String {
  case char {
    "\\" -> "\\\\"
    "\"" -> "\\\""
    "\t" -> "\\t"
    "\n" -> "\\n"
    "\r" -> "\\r"
    "\u{0008}" -> "\\b"
    "\u{000C}" -> "\\f"
    _ -> escape_control_char(char)
  }
}

fn escape_multiline_basic_char(char: String) -> String {
  case char {
    "\\" -> "\\\\"
    "\"" -> "\\\""
    "\t" | "\n" | "\r" -> char
    "\u{0008}" -> "\\b"
    "\u{000C}" -> "\\f"
    _ -> escape_control_char(char)
  }
}

fn escape_control_char(char: String) -> String {
  case string_.to_utf_codepoints(char) {
    [cp] -> {
      let codepoint = string_.utf_codepoint_to_int(cp)
      use <- bool.guard(
        !{ codepoint <= 0x1F || codepoint == 0x7F },
        return: char,
      )
      "\\u" <> escape_basic_pad_hex(int_.to_base16(codepoint), 4)
    }
    _ -> char
  }
}

fn escape_basic_pad_hex(hex: String, width: Int) -> String {
  let len = string_.length(hex)

  use <- bool.guard(len >= width, return: hex)
  string_.repeat("0", width - len) <> hex
}

fn serialize_inline_table(entries: List(#(String, Value))) -> String {
  let inner = serialize_table_entries(entries) |> string_.join(", ")
  "{" <> inner <> "}"
}

fn serialize_table_body(entries: List(#(String, Value))) -> String {
  serialize_table_entries(entries)
  |> string_.join("\n")
}

fn serialize_table_entries(entries: List(#(String, Value))) -> List(String) {
  list.map(entries, fn(entry) {
    let #(key, value) = entry
    utils.quote_key(key) <> " = " <> to_toml_value(value)
  })
}

fn parse_base(text: String, base: Int) -> Value {
  case text {
    "0x" <> text | "0o" <> text | "0b" <> text -> text
    _ -> text
  }
  |> string_.replace("_", "")
  |> int_.base_parse(base)
  |> result.map(fn(value) {
    case base {
      2 -> TomlBinaryInt(text: Some(text), value:)
      8 -> TomlOctalInt(text: Some(text), value:)
      10 -> TomlInt(text: Some(text), value:)
      16 -> TomlHexInt(text: Some(text), value:)
      _ -> invalid(text)
    }
  })
  |> result.unwrap(invalid(text))
}

fn parse_float(text: String) -> Value {
  case string_.contains(text, "."), string_.contains(text, "e") {
    True, _ -> text
    _, True -> string_.replace(text, "e", ".0e")
    _, _ -> text <> ".0"
  }
  |> string_.replace("_", "")
  |> float_.parse()
  |> result.map(fn(float) { TomlFloat(text: Some(text), value: float) })
  |> result.unwrap(invalid(text))
}

fn type_mismatch(value: Value, expected: String) -> MoltError {
  error.TypeMismatch(path: None, expected:, got: type_of(value))
}

fn require_array(
  value: Value,
  continue: fn(List(Value)) -> Result(a, MoltError),
) -> Result(a, MoltError) {
  case value {
    TomlArray(items:) | TomlArrayOfTables(items:) -> continue(items)
    _ -> Error(type_mismatch(value, "array"))
  }
}

fn require_table(
  value: Value,
  continue: fn(List(#(String, Value))) -> Result(a, MoltError),
) -> Result(a, MoltError) {
  case value {
    TomlTable(entries:) | TomlInlineTable(entries:) -> continue(entries)
    _ -> Error(type_mismatch(value, "table"))
  }
}

fn rebuild_array(original: Value, new_items: List(Value)) -> Value {
  case original {
    TomlArrayOfTables(..) -> TomlArrayOfTables(items: new_items)
    _ -> TomlArray(items: new_items)
  }
}

fn rebuild_table(
  original: Value,
  new_entries: List(#(String, Value)),
) -> Value {
  case original {
    TomlTable(..) -> TomlTable(entries: new_entries)
    _ -> TomlInlineTable(entries: new_entries)
  }
}

fn has_disallowed_literal_char(text: String) -> Bool {
  string_.to_graphemes(text)
  |> list.any(fn(char) {
    case char {
      "\t" -> False
      "'" | "\n" | "\r" -> True
      _ -> is_control_or_del(char)
    }
  })
}

fn has_disallowed_multiline_literal_char(text: String) -> Bool {
  string_.contains(text, "'''")
  || {
    string_.to_graphemes(text)
    |> list.any(fn(char) {
      case char {
        "\t" | "\n" | "\r" -> False
        _ -> is_control_or_del(char)
      }
    })
  }
}

fn is_control_or_del(char: String) -> Bool {
  case string_.to_utf_codepoints(char) {
    [cp] -> {
      let codepoint = string_.utf_codepoint_to_int(cp)
      codepoint <= 0x1F || codepoint == 0x7F
    }
    _ -> False
  }
}

fn element_to_value(element: Element(TomlKind)) -> Value {
  case element {
    T(Token(kind:, text:)) -> token_to_value(kind, text)
    N(node) -> node_to_value(node)
  }
}

fn token_to_value(kind: TomlKind, text: String) -> Value {
  case kind {
    types.BoolTrue -> TomlBool(value: True)
    types.BoolFalse -> TomlBool(value: False)
    types.Inf -> TomlInfinity(sign: Unsigned)
    types.PosInf -> TomlInfinity(sign: Positive)
    types.NegInf -> TomlInfinity(sign: Negative)
    types.NaN -> TomlNaN(sign: Unsigned)
    types.PosNaN -> TomlNaN(sign: Positive)
    types.NegNaN -> TomlNaN(sign: Negative)
    types.Integer -> parse_base(text, 10)
    types.HexInteger -> parse_base(text, 16)
    types.OctalInteger -> parse_base(text, 8)
    types.BinaryInteger -> parse_base(text, 2)
    types.Float -> parse_float(text)
    types.OffsetDateTime -> TomlOffsetDateTime(text:)
    types.LocalDateTime -> TomlLocalDateTime(text:)
    types.LocalDate -> TomlLocalDate(text:)
    types.LocalTime -> TomlLocalTime(text:)
    types.BasicString ->
      TomlBasicString(
        text: Some("\"" <> text <> "\""),
        value: utils.unescape_basic_string(text),
      )
    types.MultilineBasicString ->
      TomlMultilineBasicString(
        text: Some("\"\"\"" <> text <> "\"\"\""),
        value: utils.unescape_basic_string(text),
        open_nl: False,
      )
    types.MultilineBasicStringNl ->
      TomlMultilineBasicString(
        text: Some("\"\"\"\n" <> text <> "\"\"\""),
        value: utils.unescape_basic_string(text),
        open_nl: True,
      )
    types.LiteralString -> TomlLiteralString(value: text)
    types.MultilineLiteralString ->
      TomlMultilineLiteralString(value: text, open_nl: False)
    types.MultilineLiteralStringNl ->
      TomlMultilineLiteralString(value: text, open_nl: True)
    types.InvalidValue | _ -> invalid(text)
  }
}

fn node_to_value(node: Node(TomlKind)) -> Value {
  case node.kind {
    types.Array -> array_node_to_value(node)
    types.InlineTable -> inline_table_node_to_value(node)
    _ -> invalid("")
  }
}

fn array_node_to_value(node: Node(TomlKind)) -> Value {
  node.children
  |> list.filter_map(fn(el) {
    case el {
      N(Node(kind: types.ArrayElement, children:, ..)) ->
        case elements.find_first_value(children) {
          Some(val_el) -> Ok(element_to_value(val_el))
          None -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> TomlArray
}

fn inline_table_node_to_value(node: Node(TomlKind)) -> Value {
  node.children
  |> list.filter_map(fn(el) {
    case el {
      N(Node(kind: types.KeyValue, ..) as kv) -> {
        let key = elements.key_name(kv.children) |> option.unwrap("")
        let val = case
          elements.find_first_value(elements.value_tokens(kv.children))
        {
          Some(val_el) -> element_to_value(val_el)
          None -> invalid("")
        }
        Ok(#(key, val))
      }
      _ -> Error(Nil)
    }
  })
  |> TomlInlineTable
}

fn invalid(text: String) -> Value {
  TomlInvalid(text:)
}
