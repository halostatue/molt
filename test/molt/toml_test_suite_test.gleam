//// TOML test suite compliance tests.
////
//// Runs the toml-lang/toml-test fixtures to verify parsing correctness.
//// Valid tests must parse successfully and round-trip.
//// Invalid tests must return an error from parse.

import gleam/io
import gleam/list
import gleam/result
import gleam/string
import toml_suite

// --- Valid tests: must parse and round-trip ---

pub fn valid_toml_files_parse_test() {
  let assert Ok(results) = toml_suite.run_tests(toml_suite.Valid)

  case list.filter(results, result.is_error) {
    [] -> Nil
    failures -> {
      io.println(
        "\n=== VALID PARSE FAILURES ("
        <> string.inspect(list.length(failures))
        <> ") ===",
      )
      list.each(failures, fn(f) {
        let assert Error(error) = f
        io.println("  FAIL: " <> toml_suite.describe_error(error))
      })

      panic as "toml-test compliance failures"
    }
  }
}

pub fn valid_toml_files_round_trip_test() {
  let assert Ok(results) = toml_suite.run_round_trip_tests()
  case list.filter(results, result.is_error) {
    [] -> Nil
    failures -> {
      io.println(
        "\n=== ROUND-TRIP FAILURES ("
        <> string.inspect(list.length(failures))
        <> ") ===",
      )

      list.take(failures, 20)
      |> list.each(fn(f) {
        let assert Error(error) = f
        io.println("  FAIL: " <> toml_suite.describe_error(error))
      })
      panic as "toml-test compliance failures"
    }
  }
}

// --- Valid tests: normalize must not introduce validation errors ---

pub fn valid_toml_normalize_validate_test() {
  let assert Ok(results) = toml_suite.run_normalize_validate_tests()

  case list.filter(results, result.is_error) {
    [] -> Nil
    failures -> {
      io.println(
        "\n=== NORMALIZE-VALIDATE FAILURES ("
        <> string.inspect(list.length(failures))
        <> ") ===",
      )
      list.each(failures, fn(f) {
        let assert Error(error) = f
        io.println("  FAIL: " <> toml_suite.describe_error(error))
      })
      panic as "normalize introduced validation errors"
    }
  }
}

// --- Invalid tests: must reject ---

pub fn invalid_toml_files_reject_test() {
  let assert Ok(results) = toml_suite.run_tests(toml_suite.Invalid)

  case list.filter(results, result.is_error) {
    [] -> Nil
    failures -> {
      io.println(
        "\n=== INVALID REJECT FAILURES ("
        <> string.inspect(list.length(failures))
        <> ") ===",
      )
      list.each(list.take(failures, 20), fn(f) {
        let assert Error(error) = f
        io.println("  FAIL: " <> toml_suite.describe_error(error))
      })
      panic as "toml-test compliance failures"
    }
  }
}
