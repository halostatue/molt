//// Tests over implicit tables

import gleam/option.{Some}
import gleam/result
import molt
import molt/error
import molt/ops
import molt/value

const source = "gleam = 1\na.b.q = 42\n[a.b.c]\nd = 67\n"

pub fn rename_implicit_table_test() {
  // rename(a.b, "pismo.beach") → rewrites all a.b.* descendants
  assert Ok(
      "gleam = 1\na.\"pismo.beach\".q = 42\n[a.\"pismo.beach\".c]\nd = 67\n",
    )
    == molt.rename(doc(), "a.b", "pismo.beach")
    |> result.map(molt.to_string)
}

pub fn set_sibling_under_implicit_table_test() {
  // set(a.b.f, 67) → should produce a.b.f = 67 as a dotted key,
  // a.b should still be implicit (no [a.b] header created)
  assert Ok("gleam = 1\na.b.q = 42\na.b.f = 67\n[a.b.c]\nd = 67\n")
    == molt.set(doc(), "a.b.f", value.int(67))
    |> result.map(molt.to_string)
}

pub fn set_rejects_implicit_table_test() {
  // set(a.b, 67) must REFUSE: `a.b` is an (implicit) table, and `set` never
  // changes the kind of a structural occupant — identical to the explicit
  // table case. Destructively replacing the subtree is `place`'s job (below).
  assert Error(error.TypeMismatch(
      path: Some("a.b"),
      expected: "scalar or array value",
      got: "implicit table",
    ))
    == molt.set(doc(), "a.b", value.int(67))
}

pub fn place_scalar_over_implicit_table_test() {
  // place(a.b, 67) does what set refuses: drops the implicit table and all its
  // descendants and writes the scalar, leaving the unrelated root key intact.
  assert Ok("gleam = 1\na.b = 67\n")
    == molt.place(doc(), "a.b", value.int(67))
    |> result.map(molt.to_string)
}

pub fn place_table_over_implicit_table_test() {
  // place(a.b, {z = 9}) replaces the implicit table with an explicit [a.b].
  assert Ok("gleam = 1\n\n[a.b]\nz = 9\n")
    == molt.place(
      doc(),
      "a.b",
      value.from_table_entries([#("z", value.int(9))]),
    )
    |> result.map(molt.to_string)
}

pub fn move_keys_from_implicit_table_test() {
  // move_keys(a.b, to: a, keys: ["q"]) → moves a.b.q to a.q
  assert Ok("gleam = 1\n\n[a]\nq = 42\n[a.b.c]\nd = 67\n")
    == molt.move_keys(
      doc(),
      from: "a.b",
      to: "a",
      keys: ["q"],
      on_conflict: ops.OnConflictOverwrite,
    )
    |> result.map(molt.to_string)
}

pub fn merge_from_implicit_table_test() {
  // merge(a.b, into: x) → moves all a.b children into x
  assert Ok("gleam = 1\n\n[x]\nq = 42\n[x.c]\nd = 67\n")
    == molt.run(doc(), [
      ops.Transfer(from: "a.b", to: "x", on_conflict: ops.OnConflictError),
    ])
    |> result.map(molt.to_string)
}

pub fn set_deep_under_implicit_test() {
  // set(a.b.x.y, 99) → produces a.b.x.y = 99 as dotted key
  assert Ok("gleam = 1\na.b.q = 42\na.b.x.y = 99\n[a.b.c]\nd = 67\n")
    == molt.set(doc(), "a.b.x.y", value.int(99))
    |> result.map(molt.to_string)
}

pub fn remove_implicit_table_test() {
  // remove(a.b) → drops the whole implicit subtree (a.b.q, a.b.c, a.b.c.d).
  assert Ok("gleam = 1\n")
    == molt.remove(doc(), "a.b")
    |> result.map(molt.to_string)
}

pub fn remove_dotted_key_under_implicit_test() {
  // remove(a.b.q) → drops only the dotted scalar leaf; a.b stays implicit
  // because [a.b.c] still descends through it.
  assert Ok("gleam = 1\n[a.b.c]\nd = 67\n")
    == molt.remove(doc(), "a.b.q")
    |> result.map(molt.to_string)
}

pub fn remove_explicit_table_under_implicit_test() {
  // remove(a.b.c) → drops the explicit table; a.b stays implicit because the
  // dotted key a.b.q still descends through it.
  assert Ok("gleam = 1\na.b.q = 42\n")
    == molt.remove(doc(), "a.b.c")
    |> result.map(molt.to_string)
}

pub fn remove_implicit_table_then_set_test() {
  // Removing an implicit table then setting a new key under its former ancestor
  // must leave a consistent tree/index (compound op sequence).
  let assert Ok(doc) = molt.parse("[a.b.c]\nd = 3\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.Remove(path: "a.b"),
      ops.Set(path: "a.x", value: value.int(99)),
    ])
  let assert False = molt.has(doc2, "a.b.c")
  let assert Ok(val) = molt.get(doc2, "a.x")
  let assert Ok(99) = value.unwrap_int(val)
}

fn doc() {
  let assert Ok(d) = molt.parse(source)
  d
}
