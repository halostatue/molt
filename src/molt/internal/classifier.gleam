//// TOML value classification.
////
//// Matches text against TOML definitions.

import casefold
import gleam/bool
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import molt/internal/utils
import molt/types.{type TomlKind}

/// Matches the provided `text` value against TOML definitions for bare values.
pub fn match_type(text: String) -> Option(TomlKind) {
  case text {
    "true" -> Some(types.BoolTrue)
    "false" -> Some(types.BoolFalse)
    "inf" -> Some(types.Inf)
    "+inf" -> Some(types.PosInf)
    "-inf" -> Some(types.NegInf)
    "nan" -> Some(types.NaN)
    "+nan" -> Some(types.PosNaN)
    "-nan" -> Some(types.NegNaN)
    _ ->
      match_datetime(text)
      |> option.lazy_or(fn() { match_number(text) })
  }
}

/// Matches `text` as one of TOML's four types of timestamp (offset datetime,
/// local datetime, local date, or local time) or `None` if the value is not
/// a valid timestamp.
pub fn match_datetime(text: String) -> Option(TomlKind) {
  use <- bool.guard(
    match_offset_datetime(text),
    return: Some(types.OffsetDateTime),
  )
  use <- bool.guard(
    match_local_datetime(text),
    return: Some(types.LocalDateTime),
  )
  use <- bool.guard(match_local_date(text), return: Some(types.LocalDate))
  use <- bool.guard(match_local_time(text), return: Some(types.LocalTime))
  None
}

/// Matches `text` as one of TOML's number types (integer with subtypes for
/// binary, hex, or octal representations, or float) or `None` if the value is
/// not a valid number.
fn match_number(text: String) -> Option(TomlKind) {
  case text {
    "0x" <> rest ->
      case match_digits(rest, casefold.is_hex_grapheme) {
        True -> Some(types.HexInteger)
        False -> None
      }
    "0o" <> rest ->
      case match_digits(rest, casefold.is_octal_grapheme) {
        True -> Some(types.OctalInteger)
        False -> None
      }
    "0b" <> rest ->
      case match_digits(rest, casefold.is_binary_grapheme) {
        True -> Some(types.BinaryInteger)
        False -> None
      }
    _ -> match_decimal(text)
  }
}

/// Match `text` as an integer or floating point value or `None` if it does not
/// match.
///
/// Numbers have an optional sign (`+` or `-`) and always have an integer part
/// and an optional fractional part (`.` plus digits) and/or exponent (`e` or
/// `E` plus digits).
fn match_decimal(text: String) -> Option(TomlKind) {
  let text = case text {
    "+" <> rest | "-" <> rest -> rest
    _ -> text
  }

  // Text must start with a digit.
  use <- bool.guard(text == "", return: None)
  use <- bool.guard(
    string.slice(text, 0, 1) |> casefold.is_decimal_grapheme |> bool.negate,
    return: None,
  )

  let #(valid, integer, decimal) = take_digits(text)

  use <- bool.guard(!valid, return: None)

  // Reject leading zero like 01, 002: but `0` alone is fine and `0.x` / `0eN`
  // is fine.
  use <- bool.guard(has_invalid_leading_zero(integer), return: None)

  case decimal {
    "" -> Some(types.Integer)
    "." -> None
    "." <> fraction -> {
      let #(valid, fraction, exponent) = take_digits(fraction)

      use <- bool.guard(!valid, return: None)
      use <- bool.guard(fraction == "", return: None)

      case exponent {
        "" -> Some(types.Float)
        "e" <> exponent | "E" <> exponent -> match_exponent(exponent)
        _ -> None
      }
    }
    "e" <> exponent | "E" <> exponent -> match_exponent(exponent)
    _ -> None
  }
}

/// LocalDateTime + (Z|z|±HH:MM)
fn match_offset_datetime(text: String) -> Bool {
  // Need at least 11 chars for date+sep, then a time + offset.
  case utils.split_at(text, 10) {
    #(_, "") -> False

    #(date_part, rest) ->
      case match_local_date(date_part), rest {
        True, "T" <> time_and_offset
        | True, "t" <> time_and_offset
        | True, " " <> time_and_offset
        -> match_time_offset(time_and_offset)
        _, _ -> False
      }
  }
}

/// LocalDate + (T|t| ) + LocalTime
fn match_local_datetime(text: String) -> Bool {
  case utils.split_at(text, 10) {
    #(_, "") -> False
    #(date_part, rest) ->
      case match_local_date(date_part), rest {
        True, "T" <> time_part
        | True, "t" <> time_part
        | True, " " <> time_part
        -> match_local_time(time_part)
        _, _ -> False
      }
  }
}

/// YYYY-MM-DD
fn match_local_date(text: String) -> Bool {
  case string.split(text, "-") {
    [year, month, day] -> valid_date_parts(year:, month:, day:)
    _ -> False
  }
}

fn valid_date_parts(
  year year: String,
  month month: String,
  day day: String,
) -> Bool {
  use <- bool.guard(string.length(year) != 4, return: False)
  use <- bool.guard(string.length(month) != 2, return: False)
  use <- bool.guard(string.length(day) != 2, return: False)

  let year = int.parse(year) |> result.unwrap(-1)
  let month = int.parse(month) |> result.unwrap(0)
  let day = int.parse(day) |> result.unwrap(0)

  year >= 0
  && year < 10_000
  && month >= 1
  && month <= 12
  && day >= 1
  && day <= days_in_month(year, month)
}

/// HH:MM(:SS(.frac)?)?
fn match_local_time(text: String) -> Bool {
  case string.split(text, ":") {
    [hour, minute] -> match_time_parts(hour:, minute:, second: "", fraction: "")
    [hour, minute, second] -> {
      let #(second, fraction) = utils.split_at(second, 2)
      match_time_parts(hour:, minute:, second:, fraction:)
    }
    _ -> False
  }
}

fn match_time_parts(
  hour hour: String,
  minute minute: String,
  second second: String,
  fraction fraction: String,
) -> Bool {
  use <- bool.guard(string.length(hour) != 2, return: False)
  let hour = int.parse(hour) |> result.unwrap(-1)
  use <- bool.guard(hour < 0 || hour > 23, return: False)

  use <- bool.guard(string.length(minute) != 2, return: False)
  let minute = int.parse(minute) |> result.unwrap(-1)
  use <- bool.guard(minute < 0 || minute > 59, return: False)

  use <- bool.guard(second == "", return: True)
  use <- bool.guard(string.length(second) != 2, return: False)

  let second = int.parse(second) |> result.unwrap(-1)
  second >= 0 && second <= 60 && valid_time_fraction(fraction)
}

fn valid_time_fraction(fraction: String) -> Bool {
  case fraction {
    "" -> True
    "." -> False
    "." <> fraction -> casefold.is_decimal(fraction)
    _ -> False
  }
}

/// Match digits based on the `predicate` function (which will check for
/// binary, decimal, binary, hex, or octal digits) interleaved with underscores.
///
/// Numbers may not begin or end with underscores, must have at least one digit
/// value, and may not have consecutive underscores.
fn match_digits(text: String, predicate: fn(String) -> Bool) -> Bool {
  use <- bool.guard(text == "", return: False)
  let #(first, rest) = utils.split_at(text, 1)
  predicate(first) && do_match_digits(rest, predicate)
}

fn do_match_digits(text: String, predicate: fn(String) -> Bool) -> Bool {
  use <- bool.guard(text == "", return: True)

  case utils.split_at(text, 1) {
    #("_", "") | #("_", "_" <> _) -> False
    #("_", rest) -> do_match_digits(rest, predicate)
    #(first, rest) -> predicate(first) && do_match_digits(rest, predicate)
  }
}

/// Take a contiguous run of decimal digits and `_`. Validates the use of
/// underscores and leading zeros.
fn take_digits(text: String) -> #(Bool, String, String) {
  use <- bool.guard(text == "", return: #(False, "", ""))

  let #(first, rest) = utils.split_at(text, 1)

  use <- bool.guard(
    casefold.is_decimal_grapheme(first) |> bool.negate,
    return: #(False, "", ""),
  )

  do_take_digits(rest, [first], casefold.is_decimal_grapheme)
}

fn do_take_digits(
  text: String,
  acc: List(String),
  predicate: fn(String) -> Bool,
) -> #(Bool, String, String) {
  use <- bool.lazy_guard(text == "", return: fn() {
    #(True, utils.reverse_concat(acc), "")
  })

  case utils.split_at(text, 1) {
    #("_", "") | #("_", "_" <> _) -> #(False, "", "")
    #("_", rest) -> {
      use <- bool.guard(!predicate(string.slice(rest, 0, 1)), return: #(
        False,
        "",
        "",
      ))
      do_take_digits(rest, acc, predicate)
    }
    #(first, rest) -> {
      use <- bool.guard(
        predicate(first),
        do_take_digits(rest, [first, ..acc], predicate),
      )

      #(True, utils.reverse_concat(acc), text)
    }
  }
}

fn has_invalid_leading_zero(text: String) -> Bool {
  case text {
    "0" -> False
    "0" <> _ -> True
    _ -> False
  }
}

fn match_exponent(text: String) -> Option(TomlKind) {
  let text = case text {
    "+" <> rest | "-" <> rest -> rest
    _ -> text
  }

  use <- bool.guard(text == "", return: None)
  use <- bool.guard(
    string.slice(text, 0, 1) |> casefold.is_decimal_grapheme |> bool.negate,
    return: None,
  )

  case take_digits(text) {
    #(True, _, "") -> Some(types.Float)
    _ -> None
  }
}

/// Find the offset marker: Z, z, +, or - (the only `-` allowed in the time
/// portion is the offset). Scan from left looking for the first such marker
/// after at least 5 chars (HH:MM minimum).
fn match_time_offset(input: String) -> Bool {
  do_match_time_offset(input:, acc: [], count: 0)
}

fn do_match_time_offset(
  input input: String,
  acc acc: List(String),
  count count: Int,
) -> Bool {
  case input {
    "" -> False
    "Z" <> input | "z" <> input -> {
      input == "" && match_local_time(utils.reverse_concat(acc))
    }
    "+" <> input | "-" <> input if count >= 5 ->
      match_local_time(utils.reverse_concat(acc)) && match_offset_body(input)
    _ -> {
      let #(ch, input) = utils.split_at(input, 1)
      do_match_time_offset(input:, acc: [ch, ..acc], count: count + 1)
    }
  }
}

fn match_offset_body(text: String) -> Bool {
  case string.split(text, ":") {
    [hour, minute] -> match_time_parts(hour:, minute:, second: "", fraction: "")
    _ -> False
  }
}

fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    4 | 6 | 9 | 11 -> 30
    2 ->
      case is_leap(year) {
        True -> 29
        False -> 28
      }
    _ -> 0
  }
}

fn is_leap(year: Int) -> Bool {
  use <- bool.guard(year % 4 != 0, return: False)
  use <- bool.guard(year % 100 != 0, return: True)
  year % 400 == 0
}
