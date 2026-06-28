//// Tests for EnsureExists and MergeValues correctness invariants, including
//// indexed (a.b[i]) MergeValues cases and the unique redefinition/concretize
//// cases migrated from the old Create* op tests. This file pins the
//// EnsureExists/MergeValues behaviour directly, plus the AoT entry-key quoting
//// fix that survives the op split.

import gleam/list
import gleam/option.{Some}
import gleam/string
import molt
import molt/error
import molt/ops
import molt/types
import molt/value

// EnsureExists

// Fresh path builds the table header.
pub fn ensure_exists_fresh_table_test() {
  emits("", [ops.EnsureExists("a.b", types.Table)], "[a.b]\n")
}

// A header-implicit table is concretized to an emitted header before its child.
pub fn ensure_exists_concretizes_implicit_test() {
  emits(
    "[a.b.c]\n",
    [ops.EnsureExists("a.b", types.Table)],
    "[a.b]\n\n[a.b.c]\n",
  )
}

// A dotted-implicit table is concretized, rehoming its dotted descendants into
// the new section (bare `cst.ensure` would emit a conflicting header).
pub fn ensure_exists_concretizes_dotted_implicit_test() {
  emits("a.b.c = 1\n", [ops.EnsureExists("a.b", types.Table)], "[a.b]\nc = 1\n")
}

// A concrete table is left untouched (idempotent).
pub fn ensure_exists_noop_concrete_test() {
  emits("[a.b]\n", [ops.EnsureExists("a.b", types.Table)], "[a.b]\n")
}

// An existing array of tables family is left untouched for ArrayOfTables.
pub fn ensure_exists_noop_aot_family_test() {
  emits(
    "[[a]]\nx = 0\n",
    [ops.EnsureExists("a", types.ArrayOfTables)],
    "[[a]]\nx = 0\n",
  )
}

// Wrong kind for an existing occupant is a TypeMismatch (inverse of
// `ensure_exists_table_over_aot_mismatch`).
pub fn ensure_exists_kind_mismatch_test() {
  let doc = parse("[a.b]\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b"),
    expected: "array_of_tables",
    got: "table",
  )) = molt.ensure_exists(doc, "a.b", types.ArrayOfTables)
}

// An inline-table occupant is refused: `EnsureExists` never promotes an inline
// table into a `[section]`. Use `Representation` to convert inline <-> block.
pub fn ensure_exists_rejects_inline_occupant_test() {
  let doc = parse("a = { x = 1 }\n")
  let assert Error(error.TypeMismatch(
    path: Some("a"),
    expected: "table",
    got: "inline table",
  )) = molt.ensure_exists(doc, "a", types.Table)
}

// A scalar ancestor blocks the structure.
pub fn ensure_exists_scalar_ancestor_test() {
  let doc = parse("[a]\nx = 1\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.x.y"),
    expected: "table",
    got: "value",
  )) = molt.ensure_exists(doc, "a.x.y", types.Table)
}

// An array-valued ancestor also blocks a deep table.
pub fn ensure_exists_array_ancestor_test() {
  let doc = parse("[a]\nb = []\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b.c"),
    expected: "table",
    got: "array",
  )) = molt.ensure_exists(doc, "a.b.c", types.Table)
}

// MergeValues

// A dotted entry key is treated as a path, quoted per segment (no double-quote).
pub fn merge_values_dotted_key_is_path_test() {
  emits(
    "[a.b]\n",
    [ops.MergeValues("a.b", [#("c.d", value.int(3))], ops.OnConflictError)],
    "[a.b]\nc.d = 3\n",
  )
}

// A non-bare key is single-quoted exactly once.
pub fn merge_values_non_bare_key_single_quoted_test() {
  emits(
    "[a.b]\n",
    [ops.MergeValues("a.b", [#("'a b'", value.int(1))], ops.OnConflictError)],
    "[a.b]\n\"a b\" = 1\n",
  )
}

// MergeValues requires a concrete table: an implicit target is rejected.
pub fn merge_values_implicit_target_rejected_test() {
  let doc = parse("[a.b.c]\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b"),
    expected: "concrete table",
    got: "implicit table",
  )) =
    molt.merge_values(doc, "a.b", [#("x", value.int(1))], ops.OnConflictError)
}

// An absent target is NotFound (MergeValues never creates the table).
pub fn merge_values_absent_target_not_found_test() {
  let doc = parse("")
  let assert Error(error.NotFound(path: "a.b", at: "a.b")) =
    molt.merge_values(doc, "a.b", [#("x", value.int(1))], ops.OnConflictError)
}

// Leaf conflict honours the strategy: error / skip / overwrite.
pub fn merge_values_leaf_conflict_strategies_test() {
  let doc = parse("[a.b]\nx = 1\n")
  let assert Error(error.AlreadyExists(
    path: "a.b.x",
    current: types.IndexScalarValue(container: [
      types.KeySegment("a"),
      types.KeySegment("b"),
    ]),
  )) =
    molt.merge_values(doc, "a.b", [#("x", value.int(2))], ops.OnConflictError)

  let assert Ok(skipped) =
    molt.merge_values(doc, "a.b", [#("x", value.int(2))], ops.OnConflictSkip)
  let assert True = molt.to_string(skipped) == "[a.b]\nx = 1\n"

  let assert Ok(over) =
    molt.merge_values(
      doc,
      "a.b",
      [#("x", value.int(2))],
      ops.OnConflictOverwrite,
    )
  let assert True = molt.to_string(over) == "[a.b]\nx = 2\n"
}

// A non-colliding entry is always added, regardless of strategy.
pub fn merge_values_non_colliding_entry_always_added_test() {
  let doc = parse("[a]\nx = 1\n")
  let strategies = [
    ops.OnConflictError,
    ops.OnConflictSkip,
    ops.OnConflictOverwrite,
  ]
  list.each(strategies, fn(strategy) {
    let assert Ok(doc2) =
      molt.merge_values(doc, "a", [#("z", value.int(42))], strategy)
    let assert Ok(z) = molt.get(doc2, "a.z")
    let assert Ok(42) = value.unwrap_int(z)
  })
}

// Extending a pre-existing dotted-implicit table is legal TOML and must NOT be
// false-rejected by the validate-after pass (`[a.b]` with `c.x` already; adding
// `c.d` keeps `a.b.c` a dotted-implicit table).
pub fn merge_values_extends_dotted_implicit_allowed_test() {
  emits(
    "[a.b]\nc.x = 1\n",
    [ops.MergeValues("a.b", [#("c.d", value.int(2))], ops.OnConflictError)],
    "[a.b]\nc.x = 1\nc.d = 2\n",
  )
}

// A dotted entry redefining an existing header table is rejected (validate-after).
pub fn merge_values_redefines_header_rejected_test() {
  let doc = parse("[a.b]\n[a.b.c]\n")
  let assert Error(error.InvalidOperation("merge_values", Some(_))) =
    molt.merge_values(doc, "a.b", [#("c.d", value.int(1))], ops.OnConflictError)
}

// Merging into an array of tables entry by index works.
pub fn merge_values_aot_entry_test() {
  emits(
    "[[t]]\nx = 0\n",
    [ops.MergeValues("t[0]", [#("y", value.int(1))], ops.OnConflictError)],
    "[[t]]\nx = 0\ny = 1\n",
  )
}

// AoT entry key quoting (the double-quote fix that survives the op split)

// `append` into an array of tables quotes a non-bare entry key exactly once:
// `"a b" = 1`, never the double-quoted `"\"a b\""`.
pub fn append_aot_non_bare_key_single_quoted_test() {
  let doc = parse("[[t]]\n")
  let assert Ok(doc2) =
    molt.append(doc, "t", value.table([#("a b", value.int(1))]))
  let out = molt.to_string(doc2)
  let assert True = string.contains(out, "\"a b\" = 1")
  // No escaped quote => the key was not double-quoted.
  let assert False = string.contains(out, "\\\"")
}

// EnsureExists redefinition / concretize cases (migrated from redefine_ops)

// A scalar occupant AT the exact path blocks the table (TypeMismatch). Distinct
// from the scalar-ancestor case: here `b` itself is the scalar, not an ancestor.
pub fn ensure_exists_scalar_occupant_blocks_table_test() {
  let doc = parse("[a]\nb = 1\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b"),
    expected: "table",
    got: "value",
  )) = molt.ensure_exists(doc, "a.b", types.Table)
}

// Requesting a plain Table where an array of tables already lives is a
// TypeMismatch (the inverse of `ensure_exists_kind_mismatch`).
pub fn ensure_exists_table_over_aot_mismatch_test() {
  let doc = parse("[[a]]\nx = 1\n")
  let assert Error(error.TypeMismatch(
    path: Some("a"),
    expected: "table",
    got: "array of tables",
  )) = molt.ensure_exists(doc, "a", types.Table)
}

// A dotted-implicit table where an array of tables is requested is rejected.
pub fn ensure_exists_dotted_implicit_over_aot_mismatch_test() {
  let doc = parse("a.b.c = 1\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b"),
    expected: "array_of_tables",
    got: "implicit table",
  )) = molt.ensure_exists(doc, "a.b", types.ArrayOfTables)
}

// Concretizing a dotted-implicit table then merging a new key rehomes the
// dotted descendant under the new header and appends the merged key.
pub fn ensure_exists_dotted_reopen_then_merge_test() {
  emits(
    "a.b.c = 1\n",
    [
      ops.EnsureExists("a.b", types.Table),
      ops.MergeValues("a.b", [#("z", value.int(9))], ops.OnConflictError),
    ],
    "[a.b]\nc = 1\nz = 9\n",
  )
}

// Concretizing a header-implicit super-table (late) then merging a new key
// emits the new header before the pre-existing child header.
pub fn ensure_exists_super_table_late_then_merge_test() {
  emits(
    "[a.b.c]\nx = 1\n",
    [
      ops.EnsureExists("a.b", types.Table),
      ops.MergeValues("a.b", [#("z", value.int(9))], ops.OnConflictError),
    ],
    "[a.b]\nz = 9\n\n[a.b.c]\nx = 1\n",
  )
}

// Creating a child table when a concrete parent already exists places the new
// header after the parent's body. (Migrated from path_test.)
pub fn ensure_exists_child_after_parent_test() {
  emits(
    "[x]\na = 1\n",
    [
      ops.EnsureExists("x.y", types.Table),
      ops.MergeValues("x.y", [#("b", value.int(2))], ops.OnConflictError),
    ],
    "[x]\na = 1\n\n[x.y]\nb = 2\n",
  )
}

// Creating an array of tables under an existing section places it after the
// section's existing subtables. (Migrated from path_test.)
pub fn ensure_exists_aot_after_section_test() {
  emits(
    "[root]\nname = \"x\"\n\n[root.sub]\nk = 1\n",
    [
      ops.EnsureExists("root.items", types.ArrayOfTables),
      ops.MergeValues(
        "root.items[0]",
        [#("n", value.int(1))],
        ops.OnConflictError,
      ),
    ],
    "[root]\nname = \"x\"\n\n[root.sub]\nk = 1\n\n[[root.items]]\nn = 1\n",
  )
}

// Appending a fresh entry to an existing array of tables family adds a second
// `[[a.b]]` block.
pub fn append_extends_existing_aot_family_test() {
  emits(
    "[[a.b]]\nx = 1\n",
    [ops.Append("a.b", value.from_table_entries([#("y", value.int(2))]))],
    "[[a.b]]\nx = 1\n\n[[a.b]]\ny = 2\n",
  )
}

// MergeValues with an indexed path (a.b[i]) — migrated from indexed_create_test
//
// An index segment SELECTS an existing array of tables entry to extend, never
// constructs one. Non-resolving indexed targets surface NotFound.

const aot_doc_4 = "[[a.b]]\nx = 0\n\n[[a.b]]\nx = 1\n\n[[a.b]]\nx = 2\n\n[[a.b]]\nx = 3\n"

const aot_doc_1 = "[[a.b]]\nx = 0\n"

// Extend an existing entry by index (4-entry AoT, merge a.b[3] k=9).
pub fn merge_values_indexed_extend_existing_entry_test() {
  emits(
    aot_doc_4,
    [ops.MergeValues("a.b[3]", [#("k", value.int(9))], ops.OnConflictError)],
    "[[a.b]]\nx = 0\n\n[[a.b]]\nx = 1\n\n[[a.b]]\nx = 2\n\n[[a.b]]\nx = 3\nk = 9\n",
  )
}

// Extending with an empty entry list is a no-op.
pub fn merge_values_indexed_extend_empty_test() {
  emits(
    aot_doc_4,
    [ops.MergeValues("a.b[3]", [], ops.OnConflictError)],
    aot_doc_4,
  )
}

// Out-of-range index -> NotFound (the target entry does not resolve).
pub fn merge_values_indexed_out_of_range_test() {
  let doc = parse(aot_doc_1)
  let assert Error(error.NotFound(path: "a.b[1]", at: "a.b[1]")) =
    molt.merge_values(doc, "a.b[1]", [], ops.OnConflictError)
}

// Absent target -> NotFound (merge never constructs the AoT).
pub fn merge_values_indexed_absent_test() {
  let doc = parse("")
  let assert Error(error.NotFound(path: "a.b[0]", at: "a.b[0]")) =
    molt.merge_values(doc, "a.b[0]", [], ops.OnConflictError)
}

// Indexing into a non-AoT table -> NotFound (a.b[0] does not resolve).
pub fn merge_values_indexed_into_non_aot_table_test() {
  let doc = parse("[a.b]\nx = 0\n")
  let assert Error(error.NotFound(path: "a.b[0]", at: "a.b[0]")) =
    molt.merge_values(doc, "a.b[0]", [], ops.OnConflictError)
}

// Set / Remove / Rename / Update / Comments / InsertKey

pub fn set_new_key_test() {
  emits(
    "[server]\nport = 8080\n",
    [ops.Set("server.host", value.string("localhost"))],
    "[server]\nport = 8080\nhost = \"localhost\"\n",
  )
}

pub fn set_overwrite_test() {
  emits(
    "[server]\nport = 8080\n",
    [ops.Set("server.port", value.int(9090))],
    "[server]\nport = 9090\n",
  )
}

pub fn remove_key_test() {
  emits(
    "[server]\nhost = \"localhost\"\nport = 8080\n",
    [ops.Remove("server.host")],
    "[server]\nport = 8080\n",
  )
}

// SPEC (currently failing): index-scoped surgery on implicit tables / AoT
// families. The index segment navigates to the right entry; the surgery happens
// there; other entries are untouched. These previously no-op'd or corrupted
// because the index was dropped instead of used for navigation.

pub fn remove_indexed_implicit_table_test() {
  let doc = parse("[[srv]]\ndb.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n")
  let assert Ok(doc2) = molt.remove(doc, "srv[0].db")
  // db removed from the first entry only; the (now empty) entry still exists.
  let assert False = molt.has(doc2, "srv[0].db")
  let assert True = molt.has(doc2, "srv[0]")
  let assert True = molt.has(doc2, "srv[1].db")
  let assert Ok(v) = molt.get(doc2, "srv[1].db.host")
  let assert Ok("b") = value.unwrap_string(v)
  let assert False = molt.has(doc2, "srv[2]")
}

pub fn rename_indexed_implicit_table_test() {
  let doc = parse("[[srv]]\ndb.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n")
  let assert Ok(doc2) = molt.rename(doc, "srv[0].db", "database")
  let assert True = molt.has(doc2, "srv[0].database")
  let assert False = molt.has(doc2, "srv[0].db")
  let assert Ok(v) = molt.get(doc2, "srv[0].database.host")
  let assert Ok("a") = value.unwrap_string(v)
  // Second entry untouched.
  let assert True = molt.has(doc2, "srv[1].db")
}

pub fn insert_key_indexed_implicit_table_test() {
  let doc = parse("[[srv]]\ndb.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n")
  let assert Ok(doc2) =
    molt.insert_key(doc, "srv[0].db", "host", "port", value.int(1))
  let assert Ok(v) = molt.get(doc2, "srv[0].db.port")
  let assert Ok(1) = value.unwrap_int(v)
  // Inserted only into the first entry.
  let assert False = molt.has(doc2, "srv[1].db.port")
}

pub fn remove_indexed_aot_family_test() {
  let doc = parse("[[x]]\n[[x.a]]\np = 1\n\n[[x]]\n[[x.a]]\nr = 3\n")
  let assert Ok(doc2) = molt.remove(doc, "x[0].a")
  // x.a family removed from the first x entry only.
  let assert False = molt.has(doc2, "x[0].a")
  let assert True = molt.has(doc2, "x[1].a")
}

// Arbitrarily deep nesting: q[0] and q[1] each have x[0] and x[1] sub-families.
// Removing q[1].x[1].a must scope positionally at *both* levels (counters reset
// per parent entry), removing only that one and leaving the other three.
pub fn remove_deep_nested_aot_family_test() {
  let doc =
    parse(
      "[[q]]\n[[q.x]]\n[[q.x.a]]\np = 1\n[[q.x]]\n[[q.x.a]]\nm = 2\n"
      <> "[[q]]\n[[q.x]]\n[[q.x.a]]\nr = 3\n[[q.x]]\n[[q.x.a]]\ns = 4\n",
    )
  let assert Ok(doc2) = molt.remove(doc, "q[1].x[1].a")
  let assert True = molt.has(doc2, "q[0].x[0].a")
  let assert True = molt.has(doc2, "q[0].x[1].a")
  let assert True = molt.has(doc2, "q[1].x[0].a")
  let assert False = molt.has(doc2, "q[1].x[1].a")
}

// Exact-formatting guards for the index-scoped surgery ops, so emitted output
// cannot drift. These assert raw `to_string` (no normalization).

pub fn remove_indexed_implicit_table_format_test() {
  let doc = parse("[[srv]]\ndb.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n")
  let assert Ok(doc2) = molt.remove(doc, "srv[0].db")
  assert molt.to_string(doc2) == "[[srv]]\n\n[[srv]]\ndb.host = \"b\"\n"
}

pub fn rename_indexed_implicit_table_format_test() {
  let doc = parse("[[srv]]\ndb.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n")
  let assert Ok(doc2) = molt.rename(doc, "srv[0].db", "database")
  assert molt.to_string(doc2)
    == "[[srv]]\ndatabase.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n"
}

pub fn insert_key_indexed_implicit_table_format_test() {
  let doc = parse("[[srv]]\ndb.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n")
  let assert Ok(doc2) =
    molt.insert_key(doc, "srv[0].db", "host", "port", value.int(1))
  assert molt.to_string(doc2)
    == "[[srv]]\ndb.port = 1\ndb.host = \"a\"\n\n[[srv]]\ndb.host = \"b\"\n"
}

pub fn remove_indexed_aot_family_format_test() {
  let doc = parse("[[x]]\n[[x.a]]\np = 1\n\n[[x]]\n[[x.a]]\nr = 3\n")
  let assert Ok(doc2) = molt.remove(doc, "x[0].a")
  assert molt.to_string(doc2) == "[[x]]\n\n[[x]]\n[[x.a]]\nr = 3\n"
}

pub fn remove_negative_aot_entry_format_test() {
  let doc = parse("[[a]]\nx = 1\n\n[[a]]\nx = 2\n\n[[a]]\nx = 3\n")
  let assert Ok(doc2) = molt.remove(doc, "a[-1]")
  assert molt.to_string(doc2) == "[[a]]\nx = 1\n\n[[a]]\nx = 2\n"
}

// Removing the FIRST AoT entry must not leave an orphaned leading blank line.
// Previously entry[1]'s inter-entry separator newline was still in its leading
// trivia after entry[0] was deleted, printing as a spurious leading "\n".
pub fn remove_first_aot_entry_no_leading_blank_test() {
  // Two entries: blank line separator between them.
  let doc = parse("[[a]]\nx = 1\n\n[[a]]\nx = 2\n")
  let assert Ok(doc2) = molt.remove(doc, "a[0]")
  assert molt.to_string(doc2) == "[[a]]\nx = 2\n"
}

// Removing a non-first AoT entry must NOT strip its sibling's leading blank.
pub fn remove_middle_aot_entry_preserves_separator_test() {
  let doc = parse("[[a]]\nx = 1\n\n[[a]]\nx = 2\n\n[[a]]\nx = 3\n")
  let assert Ok(doc2) = molt.remove(doc, "a[1]")
  assert molt.to_string(doc2) == "[[a]]\nx = 1\n\n[[a]]\nx = 3\n"
}

// When there is content before the first AoT entry, removing entry[0] should
// preserve the blank line that separates the preceding content from entry[1].
pub fn remove_first_aot_entry_with_preceding_content_test() {
  let doc =
    parse("x = 1\n\n[[a]]\nname = \"apple\"\n\n[[a]]\nname = \"banana\"\n")
  let assert Ok(doc2) = molt.remove(doc, "a[0]")
  assert molt.to_string(doc2) == "x = 1\n\n[[a]]\nname = \"banana\"\n"
}

// Removing a key that lives inside an inline-table value goes through the
// "missing" remove path (inline-table interiors are not index entries). The
// document must stay consistent: the key is gone, the index agrees, and a
// later op keyed off the index still resolves. Pins the deliberate deep-object
// indexing behaviour so a future index change can't silently desync it.
pub fn remove_inline_table_interior_key_test() {
  let doc = parse("a = { b = 1, c = 2 }\nx = 9\n")
  let assert Ok(doc2) = molt.remove(doc, "a.b")
  let assert False = molt.has(doc2, "a.b")
  let assert True = molt.has(doc2, "a.c")
  let assert Error(_) = molt.get(doc2, "a.b")
  let assert Ok(doc3) = molt.set(doc2, "a.d", value.int(3))
  let assert True = molt.has(doc3, "a.d")
}

pub fn batch_set_and_remove_test() {
  emits(
    "[server]\nport = 8080\n",
    [
      ops.Set("server.host", value.string("0.0.0.0")),
      ops.Remove("server.port"),
    ],
    "[server]\nhost = \"0.0.0.0\"\n",
  )
}

pub fn rename_key_test() {
  emits(
    "[server]\nport = 8080\n",
    [ops.Rename("server.port", "listen")],
    "[server]\nlisten = 8080\n",
  )
}

// Renaming an array of tables family rewrites EVERY `[[srv]]` header, not just
// the first one.
pub fn rename_array_of_tables_family_test() {
  let doc = parse("[[srv]]\nhost = \"a\"\n\n[[srv]]\nhost = \"b\"\n")
  let assert Ok(doc2) = molt.rename(doc, "srv", "server")
  assert molt.to_string(doc2)
    == "[[server]]\nhost = \"a\"\n\n[[server]]\nhost = \"b\"\n"
  let assert Ok(2) = molt.length(doc2, "server")
  let assert False = molt.has(doc2, "srv")
}

// Nested sub-families get their prefix rewritten too: `[[srv.iface]]` becomes
// `[[server.iface]]`.
pub fn rename_nested_array_of_tables_family_test() {
  let doc =
    parse(
      "[[srv]]\n[[srv.iface]]\nip = \"1\"\n\n[[srv]]\n[[srv.iface]]\nip = \"2\"\n",
    )
  let assert Ok(doc2) = molt.rename(doc, "srv", "server")
  let assert Ok(v1) = molt.get(doc2, "server[0].iface[0].ip")
  let assert Ok("1") = value.unwrap_string(v1)
  let assert Ok(v2) = molt.get(doc2, "server[1].iface[0].ip")
  let assert Ok("2") = value.unwrap_string(v2)
  let assert False = molt.has(doc2, "srv")
}

pub fn ensure_exists_creates_empty_table_test() {
  emits(
    "name = \"test\"\n",
    [ops.EnsureExists("server", types.Table)],
    "name = \"test\"\n\n[server]\n",
  )
}

pub fn update_value_test() {
  emits(
    "[server]\nport = 8080\n",
    [ops.Update("server.port", fn(_) { Ok(value.int(9090)) })],
    "[server]\nport = 9090\n",
  )
}

pub fn update_error_propagates_test() {
  let doc = parse("[server]\nport = 8080\n")
  let assert Error(error.UpdateError("nope")) =
    molt.run(doc:, ops: [
      ops.Update("server.port", fn(_) { Error(error.UpdateError("nope")) }),
    ])
}

pub fn set_comments_test() {
  emits(
    "[server]\nport = 8080\n",
    [
      ops.SetComments("server.port", ops.Comments(["Listen port"], option.None)),
    ],
    "[server]\n# Listen port\nport = 8080\n",
  )
}

pub fn move_comments_test() {
  emits(
    "[server]\n# Important port\nport = 8080\nhost = \"localhost\"\n",
    [ops.MoveComments("server.port", "server.host")],
    "[server]\nport = 8080\n# Important port\nhost = \"localhost\"\n",
  )
}

pub fn insert_key_before_test() {
  emits(
    "[server]\nport = 8080\ndebug = false\n",
    [ops.InsertKey("server", "debug", "host", value.string("localhost"))],
    "[server]\nport = 8080\nhost = \"localhost\"\ndebug = false\n",
  )
}

// Move / Rename / MoveKeys / Transfer

pub fn move_key_within_table_test() {
  let doc = parse("[server]\nhost = \"localhost\"\nport = 8080\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [ops.Move("server.host", "server.addr")])
  let assert Ok(v) = molt.get(doc: doc2, path: "server.addr")
  let assert Ok("localhost") = value.unwrap_string(v)
  let assert False = molt.has(doc: doc2, path: "server.host")
}

pub fn move_preserves_comment_test() {
  let doc =
    parse("[server]\n# The host address\nhost = \"localhost\"\nport = 8080\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [ops.Move("server.host", "server.addr")])
  assert "[server]\nport = 8080\n# The host address\naddr = \"localhost\"\n"
    == molt.to_string(doc2)
}

pub fn move_between_tables_test() {
  let doc = parse("[source]\nkey = 42\n\n[dest]\nother = 1\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [ops.Move("source.key", "dest.key")])
  let assert Ok(v) = molt.get(doc: doc2, path: "dest.key")
  let assert Ok(42) = value.unwrap_int(v)
  let assert False = molt.has(doc: doc2, path: "source.key")
}

pub fn move_to_existing_key_collides_test() {
  let doc = parse("[a]\nx = 1\ny = 2\n")
  let assert Error(error.AlreadyExists(path: "a.y", ..)) =
    molt.run(doc:, ops: [ops.Move("a.x", "a.y")])
}

pub fn move_missing_source_not_found_test() {
  let doc = parse("[a]\nx = 1\n")
  let assert Error(error.NotFound(path: "a.nope", at: "a.nope")) =
    molt.run(doc:, ops: [ops.Move("a.nope", "a.y")])
}

pub fn move_missing_source_beats_dest_collision_test() {
  // Source first (mv semantics): a missing source is NotFound even when the
  // destination name is taken — not AlreadyExists.
  let doc = parse("[a]\nx = 1\ny = 2\n")
  let assert Error(error.NotFound(path: "a.nope", at: "a.nope")) =
    molt.run(doc:, ops: [ops.Move("a.nope", "a.y")])
}

pub fn rename_to_existing_key_collides_test() {
  let doc = parse("[a]\nx = 1\ny = 2\n")
  let assert Error(error.AlreadyExists(path: "a.y", ..)) =
    molt.run(doc:, ops: [ops.Rename("a.x", "y")])
}

pub fn rename_missing_source_beats_dest_collision_test() {
  // Source first: a missing source wins over a taken destination name.
  let doc = parse("[a]\nx = 1\ny = 2\n")
  let assert Error(error.NotFound(path: "a.z", at: "a.z")) =
    molt.run(doc:, ops: [ops.Rename("a.z", "y")])
}

pub fn move_keys_test() {
  let doc = parse("[source]\na = 1\nb = 2\n\n[dest]\nc = 3\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.MoveKeys("source", "dest", ["a", "b"], ops.OnConflictError),
    ])
  let assert Ok(v) = molt.get(doc: doc2, path: "dest.a")
  let assert Ok(1) = value.unwrap_int(v)
  let assert False = molt.has(doc: doc2, path: "source.a")
}

pub fn move_keys_conflict_error_test() {
  let doc = parse("[source]\na = 1\n\n[dest]\na = 99\n")
  let assert Error(error.AlreadyExists(path: "dest.a", ..)) =
    molt.run(doc:, ops: [
      ops.MoveKeys("source", "dest", ["a"], ops.OnConflictError),
    ])
}

pub fn move_keys_conflict_skip_test() {
  let doc = parse("[source]\na = 1\n\n[dest]\na = 99\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.MoveKeys("source", "dest", ["a"], ops.OnConflictSkip),
    ])
  let assert Ok(v) = molt.get(doc: doc2, path: "dest.a")
  let assert Ok(99) = value.unwrap_int(v)
}

pub fn move_keys_conflict_overwrite_test() {
  let doc = parse("[source]\na = 1\n\n[dest]\na = 99\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.MoveKeys("source", "dest", ["a"], ops.OnConflictOverwrite),
    ])
  let assert Ok(v) = molt.get(doc: doc2, path: "dest.a")
  let assert Ok(1) = value.unwrap_int(v)
}

pub fn move_keys_preserves_comments_test() {
  let doc = parse("[source]\n# important note\na = 1\n\n[dest]\nc = 3\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.MoveKeys("source", "dest", ["a"], ops.OnConflictError),
    ])
  assert "[source]\n\n[dest]\nc = 3\n# important note\na = 1\n"
    == molt.to_string(doc2)
}

pub fn transfer_merges_table_test() {
  let doc = parse("[source]\na = 1\nb = 2\n\n[dest]\nc = 3\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [ops.Transfer("source", "dest", ops.OnConflictError)])
  let assert Ok(v) = molt.get(doc: doc2, path: "dest.a")
  let assert Ok(1) = value.unwrap_int(v)
  let assert False = molt.has(doc: doc2, path: "source")
}

pub fn move_table_test() {
  let doc = parse("[server]\nhost = \"localhost\"\nport = 8080\n")
  let assert Ok(doc2) = molt.run(doc:, ops: [ops.Move("server", "backend")])
  let assert Ok(v) = molt.get(doc: doc2, path: "backend.host")
  let assert Ok("localhost") = value.unwrap_string(v)
  let assert False = molt.has(doc: doc2, path: "server")
}

// Transfer accepts an array of tables entry as its source: its keys move to the
// destination and the (now empty) entry is removed, shrinking the array.
pub fn transfer_aot_entry_to_table_test() {
  let doc = parse("[[srv]]\nhost = \"a\"\nport = 1\n\n[[srv]]\nhost = \"b\"\n")
  let assert Ok(doc2) =
    molt.transfer(doc, "srv[0]", "database", ops.OnConflictError)
  let assert Ok(1) = molt.length(doc2, "srv")
  let assert Ok(a) = molt.get(doc2, "database.host")
  let assert Ok("a") = value.unwrap_string(a)
  let assert Ok(p) = molt.get(doc2, "database.port")
  let assert Ok(1) = value.unwrap_int(p)
  // The surviving entry is the former srv[1].
  let assert Ok(h) = molt.get(doc2, "srv[0].host")
  let assert Ok("b") = value.unwrap_string(h)
}

// Append / Insert / Concat

pub fn append_inline_array_test() {
  emits(
    "[config]\ntags = [\"a\", \"b\"]\n",
    [ops.Append("config.tags", value.string("c"))],
    "[config]\ntags = [\"a\", \"b\", \"c\"]\n",
  )
}

pub fn insert_inline_array_test() {
  emits(
    "[config]\ntags = [\"a\", \"c\"]\n",
    [ops.Insert("config.tags", 1, value.string("b"))],
    "[config]\ntags = [\"a\", \"b\", \"c\"]\n",
  )
}

pub fn concat_inline_array_test() {
  let doc = parse("nums = [1]\n")
  let assert Ok(doc2) = molt.concat(doc, "nums", [value.int(2), value.int(3)])
  assert "nums = [1, 2, 3]\n" == molt.to_normalized_string(doc2)
}

pub fn concat_array_of_tables_test() {
  let doc = parse("[[a.b]]\nx = 0\n")
  let assert Ok(doc2) =
    molt.concat(doc, "a.b", [
      value.table([#("x", value.int(1))]),
      value.table([#("x", value.int(2))]),
    ])
  assert "[[a.b]]\nx = 0\n\n[[a.b]]\nx = 1\n\n[[a.b]]\nx = 2\n"
    == molt.to_normalized_string(doc2)
}

pub fn concat_empty_is_noop_test() {
  let doc = parse("nums = [1, 2]\n")
  let assert Ok(doc2) = molt.concat(doc, "nums", [])
  assert "nums = [1, 2]\n" == molt.to_string(doc2)
}

pub fn concat_empty_on_missing_path_rejected_test() {
  // An empty value list is a no-op only on a valid array target; a missing path
  // still errors (concat validates the target regardless of list length).
  let doc = parse("nums = [1, 2]\n")
  let assert Error(error.NotFound(path: "no.such.path", at: "no.such.path")) =
    molt.concat(doc, "no.such.path", [])
}

pub fn concat_atomic_on_bad_value_test() {
  // A non-table value mid-list aborts the whole op; the AoT is untouched.
  let doc = parse("[[a.b]]\nx = 0\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b"),
    expected: "table",
    got: "integer",
  )) =
    molt.concat(doc, "a.b", [value.table([#("x", value.int(1))]), value.int(9)])
}

pub fn concat_into_aot_index_rejected_test() {
  // a.b[i] selects a table entry, not the array of tables itself.
  let doc = parse("[[a.b]]\nx = 0\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b[0]"),
    expected: "array or array of tables",
    got: "array of tables entry",
  )) = molt.concat(doc, "a.b[0]", [value.table([#("x", value.int(1))])])
}

pub fn append_into_scalar_element_rejected_test() {
  // Regression: appending at a scalar array element must be a TypeMismatch,
  // never silently wrap the element ([1, 2] -> [[5], 2]).
  let doc = parse("a = [1, 2]\n")
  let assert Error(error.TypeMismatch(
    path: Some("a[0]"),
    expected: "array",
    got: "scalar value",
  )) = molt.append(doc, "a[0]", value.int(5))
}

pub fn insert_into_scalar_element_rejected_test() {
  // Regression: insert shares the same helper as append.
  let doc = parse("a = [1, 2]\n")
  let assert Error(error.TypeMismatch(
    path: Some("a[0]"),
    expected: "array",
    got: "scalar value",
  )) = molt.run(doc:, ops: [ops.Insert("a[0]", 0, value.int(5))])
}

// Body-table / array of tables dispatch

pub fn set_body_table_creates_section_test() {
  emits(
    "[a]\nx = 1\n",
    [
      ops.EnsureExists("a.b", types.Table),
      ops.MergeValues("a.b", [#("k", value.int(5))], ops.OnConflictError),
    ],
    "[a]\nx = 1\n\n[a.b]\nk = 5\n",
  )
}

pub fn set_nested_body_table_in_aot_entry_test() {
  emits(
    "[[products]]\nname = \"widget\"\n",
    [
      ops.EnsureExists("products[0].metadata", types.Table),
      ops.MergeValues(
        "products[0].metadata",
        [#("version", value.int(2))],
        ops.OnConflictError,
      ),
    ],
    "[[products]]\nname = \"widget\"\n\n[products.metadata]\nversion = 2\n",
  )
}

pub fn set_on_aot_header_rejected_test() {
  // Setting a scalar directly on an array of tables path (not an entry) errors.
  let doc = parse("[[products]]\nname = \"a\"\n")
  let assert Error(error.TypeMismatch(path: Some("products"), ..)) =
    molt.run(doc:, ops: [ops.Set("products", value.string("nope"))])
}

pub fn set_on_empty_document_test() {
  emits(
    "",
    [ops.Set("greeting", value.string("hello"))],
    "greeting = \"hello\"\n",
  )
}

pub fn set_deep_new_path_creates_implicit_test() {
  emits("", [ops.Set("a.b.c", value.int(42))], "a.b.c = 42\n")
}

pub fn delete_entire_array_of_tables_test() {
  emits(
    "[[products]]\nname = \"a\"\n\n[[products]]\nname = \"b\"\n",
    [ops.Remove("products")],
    "\n",
  )
}

pub fn update_inline_array_element_test() {
  let doc = parse("nums = [10, 20, 30]\n")
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.Update("nums[0]", fn(v) {
        case value.unwrap_int(v) {
          Ok(n) -> Ok(value.int(n * 2))
          Error(e) -> Error(e)
        }
      }),
    ])
  let assert Ok(v) = molt.get(doc: doc2, path: "nums[0]")
  let assert Ok(20) = value.unwrap_int(v)
}

pub fn set_out_of_bounds_rejected_test() {
  let doc = parse("nums = [1, 2, 3]\n")
  let assert Error(error.NotFound(path: "nums[5]", at: "nums[5]")) =
    molt.run(doc:, ops: [ops.Set("nums[5]", value.int(99))])
}

pub fn update_error_constructor_test() {
  assert error.UpdateError("something went wrong")
    == molt.update_error("something went wrong")
}

fn parse(src: String) -> types.Document {
  let assert Ok(doc) = molt.parse(src)
  doc
}

fn emits(src: String, operations: List(ops.Operation), expected: String) {
  let doc = parse(src)
  let assert Ok(doc2) = molt.run(doc:, ops: operations)
  let normalized = molt.normalize(doc2)
  assert molt.document_errors(normalized) == []
  let assert True = molt.to_string(normalized) == expected
}
