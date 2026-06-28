//// Nested array of tables corner cases: value navigation through `AoT[i].sub[j]`
//// paths, and sub-table scoping (a `[a.b]` header under `[[a]]` belongs to
//// exactly one entry). These are the gnarliest TOML shapes and are hard to
//// exercise inside the broader worked-example tests. Index-construction
//// invariants for these shapes live in `index_test.gleam`.

import gleam/result
import gleam/string
import molt
import molt/error
import molt/value

pub fn nested_array_of_tables_get_test() {
  let assert Ok(doc) =
    molt.parse(
      "
[[servers]]
name = 'alpha'

[[servers.interfaces]]
ip = '10.0.0.1'

[[servers.interfaces]]
ip = '10.0.0.2'

[[servers]]
name = 'beta'

[[servers.interfaces]]
ip = '10.1.0.1'
",
    )

  let assert Ok("'alpha'") =
    molt.get(doc:, path: "servers[0].name")
    |> result.map(value.to_toml_value)
  let assert Ok("'beta'") =
    molt.get(doc:, path: "servers[1].name")
    |> result.map(value.to_toml_value)

  let assert Ok("'10.0.0.1'") =
    molt.get(doc:, path: "servers[0].interfaces[0].ip")
    |> result.map(value.to_toml_value)
  let assert Ok("'10.0.0.2'") =
    molt.get(doc:, path: "servers[0].interfaces[1].ip")
    |> result.map(value.to_toml_value)
  let assert Ok("'10.1.0.1'") =
    molt.get(doc:, path: "servers[1].interfaces[0].ip")
    |> result.map(value.to_toml_value)
}

pub fn aot_subtable_scoping_test() {
  // [abc.def] belongs to abc[1] only. Accessing it via abc[0] or abc[2]
  // must return not-found, not silently borrow the wrong entry's sub-table.
  let assert Ok(doc) =
    molt.parse(
      "
[[abc]]
a = 1

[[abc]]
a = 2

[abc.def]
q = 42

[[abc]]
a = 3

[xyz]
alpha = \"beta\"

[[abc]]
a = 4
",
    )

  assert Ok("42")
    == molt.get(doc:, path: "abc[1].def.q") |> result.map(value.to_toml_value)

  assert Error(error.NotFound("abc[0].def.q", "abc[0].def.q"))
    == molt.get(doc:, path: "abc[0].def.q")

  assert Error(error.NotFound("abc[2].def.q", "abc[2].def.q"))
    == molt.get(doc:, path: "abc[2].def.q")
}

// SPEC (currently failing): negative indices must resolve against array-of-
// tables entries exactly as they do against array values — `-1` is the last
// entry. Today AoT entry lookups route through the index (keyed by positive
// position), so negatives miss before the negative-aware navigation runs.
pub fn negative_index_aot_entry_get_test() {
  let assert Ok(doc) =
    molt.parse("[[a]]\nx = 1\n\n[[a]]\nx = 2\n\n[[a]]\nx = 3\n")

  assert Ok("3")
    == molt.get(doc:, path: "a[-1].x") |> result.map(value.to_toml_value)
  assert Ok("2")
    == molt.get(doc:, path: "a[-2].x") |> result.map(value.to_toml_value)
  assert True == molt.has(doc:, path: "a[-1]")
}

pub fn negative_index_aot_entry_remove_test() {
  let assert Ok(doc) =
    molt.parse("[[a]]\nx = 1\n\n[[a]]\nx = 2\n\n[[a]]\nx = 3\n")
  // Removing the last entry leaves two; the new last is the former second.
  let assert Ok(doc2) = molt.remove(doc:, path: "a[-1]")
  assert Ok("2")
    == molt.get(doc: doc2, path: "a[-1].x") |> result.map(value.to_toml_value)
  assert False == molt.has(doc: doc2, path: "a[2]")
}

pub fn negative_index_multi_level_test() {
  let assert Ok(doc) =
    molt.parse(
      "[[srv]]\nhost = [{key = \"a0\"}, {key = \"a1\"}]\n\n[[srv]]\nhost = [{key = \"b0\"}, {key = \"b1\"}]\n",
    )
  // Negative index at the AoT level and the array level together.
  assert Ok("\"b1\"")
    == molt.get(doc:, path: "srv[-1].host[-1].key")
    |> result.map(value.to_toml_value)
}

// Negative indices at every nested array of tables level resolve the same node
// as the equivalent positive path.
pub fn negative_index_deeply_nested_get_test() {
  let assert Ok(doc) =
    molt.parse(
      "[[q]]\n[[q.x]]\n[[q.x.a]]\np = 1\n[[q.x]]\n[[q.x.a]]\nm = 2\n"
      <> "[[q]]\n[[q.x]]\n[[q.x.a]]\nr = 3\n",
    )
  assert molt.get(doc, "q[-1].x[-1].a[-1].r")
    == molt.get(doc, "q[1].x[0].a[0].r")
  assert molt.get(doc, "q[-2].x[-1].a[-1].m")
    == molt.get(doc, "q[0].x[1].a[0].m")
  assert Ok("3")
    == molt.get(doc, "q[-1].x[-1].a[-1].r") |> result.map(value.to_toml_value)
}

// An out-of-range index must report the error against the path the caller
// wrote (the original `-9`), never a normalized value.
pub fn out_of_range_index_reports_provided_path_test() {
  let assert Ok(doc) =
    molt.parse("[[a]]\nx = 1\n\n[[a]]\nx = 2\n\n[[a]]\nx = 3\n")
  let assert Error(e) = molt.get(doc:, path: "a[-9].x")
  assert string.contains(error.describe_error(e), "-9")
}

pub fn array_of_tables_entry_value_navigation_test() {
  let assert Ok(doc) =
    molt.parse(
      "
[[items]]
tags = ['a', 'b', 'c']

[[items]]
tags = ['x', 'y']
",
    )

  assert Ok("'b'")
    == molt.get(doc:, path: "items[0].tags[1]")
    |> result.map(value.to_toml_value)
  assert Ok("'y'")
    == molt.get(doc:, path: "items[1].tags[1]")
    |> result.map(value.to_toml_value)
}
