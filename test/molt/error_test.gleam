//// Error-variant coverage: InvalidDocument, InvalidTomlValue, and NotFound.
//// These isolate error paths that are awkward to reach from the worked-example
//// round-trip tests. The `at:` field of NotFound (deepest *resolved* path) is
//// pinned via cst.get, which exercises the resolver's visited tracking.

import gleam/option.{Some}
import molt
import molt/cst
import molt/error
import molt/ops
import molt/types.{IndexSegment, KeySegment}
import molt/value

pub fn invalid_document_blocks_operations_test() {
  let doc = parse("a.b = 1\na.b.c = 2\n")
  assert molt.has_errors(doc)
  assert Error(error.InvalidDocument) == molt.get(doc:, path: "a.b")
  assert Error(error.InvalidDocument)
    == molt.run(doc:, ops: [ops.Set(path: "a.b", value: value.int(1))])
}

pub fn invalid_toml_value_blocked_by_set_test() {
  let assert Error(error.InvalidTomlValue(path: "x", text: "")) =
    parse("x = 1\n")
    |> molt.run(ops: [ops.Set(path: "x", value: invalid_value())])
}

pub fn invalid_toml_value_blocked_by_place_test() {
  let assert Error(error.InvalidTomlValue(path: "x", text: "")) =
    parse("x = 1\n")
    |> molt.run(ops: [ops.Place(path: "x", value: invalid_value())])
}

pub fn invalid_toml_value_blocked_by_append_test() {
  let assert Error(error.InvalidTomlValue(path: "arr", text: "")) =
    parse("arr = [1, 2]\n")
    |> molt.run(ops: [ops.Append(path: "arr", value: invalid_value())])
}

pub fn invalid_toml_value_blocked_by_insert_test() {
  let assert Error(error.InvalidTomlValue(path: "arr", text: "")) =
    parse("arr = [1, 2]\n")
    |> molt.run(ops: [
      ops.Insert(path: "arr", before: 0, value: invalid_value()),
    ])
}

pub fn set_section_table_value_rejected_test() {
  let doc = parse("")
  let assert Ok(tbl) =
    value.as_section_table(value.table([#("port", value.int(8080))]))
  let assert Error(error.TypeMismatch(
    path: Some("server"),
    expected: "scalar, array, or inline-table value",
    got: "table",
  )) = molt.run(doc:, ops: [ops.Set(path: "server", value: tbl)])
}

pub fn set_array_of_tables_value_rejected_test() {
  let doc = parse("")
  let assert Ok(aot) =
    value.as_array_of_tables(
      value.array([value.table([#("name", value.string("a"))])]),
    )
  let assert Error(error.TypeMismatch(
    path: Some("items"),
    expected: "scalar, array, or inline-table value",
    got: "array_of_tables",
  )) = molt.run(doc:, ops: [ops.Set(path: "items", value: aot)])
}

pub fn place_table_value_updates_header_test() {
  let doc = parse("[server]\nport = 8080\n")
  let assert Ok(tbl) =
    value.as_section_table(value.table([#("host", value.string("localhost"))]))
  let assert Ok(doc2) =
    molt.run(doc:, ops: [ops.Place(path: "server", value: tbl)])
  assert molt.to_string(doc2) == "[server]\nhost = \"localhost\"\n"
}

pub fn inline_table_still_inline_when_set_test() {
  let doc = parse("")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.Set(path: "x", value: value.table([#("k", value.int(1))])),
    ])
  assert molt.to_string(doc2) == "x = {k = 1}\n"
}

pub fn not_found_simple_key_test() {
  assert Error(error.NotFound(path: "server.nope", at: "server.nope"))
    == parse("[server]\nport = 8080\n") |> molt.get(path: "server.nope")
}

pub fn not_found_index_in_array_test() {
  assert Error(error.NotFound(path: "arr[10]", at: "arr[10]"))
    == parse("arr = [1, 2, 3]\n") |> molt.get(path: "arr[10]")
}

pub fn not_found_key_in_inline_table_test() {
  assert Error(error.NotFound(path: "t.c", at: "t.c"))
    == parse("t = {a = 1, b = 2}\n") |> molt.get(path: "t.c")
}

pub fn not_found_array_of_tables_index_test() {
  assert Error(error.NotFound(path: "item[5]", at: "item[5]"))
    == parse("[[item]]\nname = \"a\"\n\n[[item]]\nname = \"b\"\n")
    |> molt.get(path: "item[5]")
}

pub fn not_found_key_after_array_of_tables_test() {
  assert Error(error.NotFound(path: "item[0].nope", at: "item[0].nope"))
    == parse("[[item]]\nname = \"a\"\n\n[[item]]\nname = \"b\"\n")
    |> molt.get(path: "item[0].nope")
}

pub fn cst_not_found_key_in_table_test() {
  assert Error(error.NotFound(path: "server.nope", at: "server"))
    == parse("[server]\nport = 8080\n")
    |> cst.from_document()
    |> cst.get(path: [KeySegment("server"), KeySegment("nope")])
}

pub fn cst_not_found_nested_table_key_test() {
  assert Error(error.NotFound(at: "a.b", path: "a.b.nope"))
    == parse("[a]\n[a.b]\nkey = 1\n")
    |> cst.from_document()
    |> cst.get(path: [
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("nope"),
    ])
}

pub fn cst_not_found_inline_table_key_test() {
  assert Error(error.NotFound(at: "t.inner", path: "t.inner.nope"))
    == parse("t = {inner = {x = 1}}\n")
    |> cst.from_document()
    |> cst.get(path: [
      KeySegment("t"),
      KeySegment("inner"),
      KeySegment("nope"),
    ])
}

pub fn cst_not_found_array_index_test() {
  assert Error(error.NotFound(at: "arr", path: "arr[10]"))
    == parse("arr = [1, 2, 3]\n")
    |> cst.from_document()
    |> cst.get(path: [KeySegment("arr"), IndexSegment(10)])
}

fn invalid_value() -> value.Value {
  let assert Ok(bad_doc) = molt.parse("[x]\na.b = 1\na.b.c = 2\n")
  let root = cst.from_document(bad_doc)
  let assert Ok(kv) = cst.get(node: root, path: [KeySegment("x")])
  value.from_cst(kv)
}

fn parse(source: String) -> types.Document {
  let assert Ok(doc) = molt.parse(source)
  doc
}
