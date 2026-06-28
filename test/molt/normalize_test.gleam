//// Tests for whitespace/layout normalization: `normalize` and
//// `to_normalized_string`. Covers canonical spacing around `=`, blank lines
//// between tables, trailing-newline collapse, array and inline-table interior
//// spacing, multiline collapse, empty containers, and the deliberate
//// preservation of comment-bearing layouts (the library's reason to exist).
//// Also pins the API contracts: a normalized document is still usable, and
//// `to_normalized_string` equals `normalize |> to_string`.

import gleam/result
import molt
import molt/value

pub fn normalize_spaces_around_equals_test() {
  assert_normalized("x=1\ny  =  2\n", to: "x = 1\ny = 2\n")
}

pub fn normalize_blank_line_between_tables_test() {
  assert_normalized(
    "[a]\nx = 1\n[b]\ny = 2\n",
    to: "[a]\nx = 1\n\n[b]\ny = 2\n",
  )
}

pub fn normalize_trailing_newline_test() {
  assert_normalized("x = 1\n\n\n", to: "x = 1\n")
}

pub fn normalize_array_interior_test() {
  assert_normalized("x=[1,2,  3]\n", to: "x = [1, 2, 3]\n")
}

pub fn normalize_array_collapses_comment_free_multiline_test() {
  assert_normalized("x = [\n  1,\n  2,\n  3,\n]\n", to: "x = [1, 2, 3]\n")
}

pub fn normalize_empty_array_test() {
  assert_normalized("x = [   ]\n", to: "x = []\n")
}

pub fn normalize_inline_table_is_padded_test() {
  assert_normalized("t={a=1,b=2}\n", to: "t = { a = 1, b = 2 }\n")
}

pub fn normalize_empty_inline_table_test() {
  assert_normalized("t = {  }\n", to: "t = {}\n")
}

pub fn normalize_nested_array_and_inline_table_test() {
  assert_normalized(
    "t = {arr=[1,2],pos={x=1,y=2}}\n",
    to: "t = { arr = [1, 2], pos = { x = 1, y = 2 } }\n",
  )
}

pub fn normalize_preserves_array_with_comment_test() {
  let src = "x = [\n  1, # one\n  2,\n]\n"
  assert_normalized(src, to: src)
}

pub fn normalize_preserves_inline_table_with_comment_test() {
  let src = "t = {\n  a = 1, # k\n  b = 2,\n}\n"
  assert_normalized(src, to: src)
}

pub fn normalize_preserves_trailing_comment_on_table_header_test() {
  assert_normalized(
    "[server] # production\nport = 8080\n",
    to: "[server] # production\nport = 8080\n",
  )
}

pub fn normalize_preserves_trailing_comment_on_aot_header_test() {
  assert_normalized(
    "[[plugins]] # auth plugin\nname = \"auth\"\n",
    to: "[[plugins]] # auth plugin\nname = \"auth\"\n",
  )
}

pub fn normalize_does_not_touch_string_contents_test() {
  assert_normalized("x=[\"a, b\",'c=d']\n", to: "x = [\"a, b\", 'c=d']\n")
}

pub fn normalize_returns_usable_document_test() {
  let assert Ok(normalized) =
    molt.parse("x=1\n")
    |> result.map(molt.normalize)

  let assert Ok(1) =
    molt.get(normalized, "x")
    |> result.try(value.unwrap_int)

  assert Ok("x = 99\n")
    == molt.set(normalized, "x", value.int(99))
    |> result.map(molt.to_string)
}

pub fn normalize_equivalent_to_to_normalized_string_test() {
  let assert Ok(doc) = molt.parse("[a]\nx=1\n[b]\ny=2\n")
  assert molt.to_normalized_string(doc)
    == { doc |> molt.normalize |> molt.to_string }
}

fn assert_normalized(from: String, to to: String) {
  let assert Ok(doc) = molt.parse(from)
  assert molt.normalize(doc) |> molt.to_string == to
}
