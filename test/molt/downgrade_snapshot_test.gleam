//// Tests using the TOML suite fixtures to for `molt.to_string` with TOML 1.0
//// format output.

import birdie
import gleam/list
import gleam/result
import gleam/string
import molt
import toml_suite

// Snapshot tests for v1.0 downgrade of 1.1-only fixtures

pub fn downgrade_string_escape_esc_test() {
  downgrade_fixture("string/escape-esc")
}

pub fn downgrade_string_hex_escape_test() {
  downgrade_fixture("string/hex-escape")
}

pub fn downgrade_datetime_no_seconds_test() {
  downgrade_fixture("datetime/no-seconds")
}

pub fn downgrade_inline_table_newline_test() {
  downgrade_fixture("inline-table/newline")
}

pub fn downgrade_inline_table_newline_comment_test() {
  downgrade_fixture("inline-table/newline-comment")
}

// Bulk spec-1.1.0 downgrade tests

pub fn downgrade_spec_1_1_0_test() {
  let assert Ok(files) = toml_suite.read_fixture_directory("valid/spec-1.1.0")

  let output =
    list.map(files, fn(file) {
      let #(path, content) = file

      let assert Ok(downgraded) =
        molt.parse_bits(content)
        |> result.map(molt.set_version(_, to: molt.v1_0))
        |> result.map(molt.to_string)

      "--- " <> path <> " ---\n" <> downgraded
    })
    |> string.join("\n")

  birdie.snap(content: output, title: "downgrade/spec-1.1.0")
}

fn downgrade_fixture(name: String) {
  let file = toml_suite.fixture_path("valid/" <> name <> ".toml")
  let assert Ok(content) = toml_suite.read_fixture(file)
  let assert Ok(output) =
    molt.parse_bits(content)
    |> result.map(molt.set_version(_, to: molt.v1_0))
    |> result.map(molt.to_string)

  birdie.snap(content: output, title: "downgrade/" <> name)
}
