//// Validation tests for the internal index to test a few corner cases

import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import molt
import molt/error
import molt/internal/document/index
import molt/internal/path
import molt/ops
import molt/types.{
  type DocumentIndex, type IndexEntry, type Path, IndexSegment, KeySegment,
}
import molt/value

pub fn implicit_table_a_test() {
  let assert Ok(types.IndexImplicitTable(..)) =
    get_index_path([KeySegment("a")])
}

pub fn implicit_table_a_b_test() {
  let assert Ok(types.IndexImplicitTable(..)) =
    get_index_path([KeySegment("a"), KeySegment("b")])
}

pub fn implicit_table_a_b_c_test() {
  let assert Ok(types.IndexImplicitTable(..)) =
    get_index_path([KeySegment("a"), KeySegment("b"), KeySegment("c")])
}

pub fn implicit_table_a_b_c_d_test() {
  let assert Ok(types.IndexImplicitTable(..)) =
    get_index_path([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("c"),
      KeySegment("d"),
    ])
}

pub fn explicit_table_a_b_c_d_e_test() {
  let assert Ok(types.IndexTable(..)) =
    get_index_path([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("c"),
      KeySegment("d"),
      KeySegment("e"),
    ])
}

pub fn explicit_table_a_b_c_d_f_test() {
  let assert Ok(types.IndexTable(..)) =
    get_index_path([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("c"),
      KeySegment("d"),
      KeySegment("f"),
    ])
}

pub fn aot_a_b_g_test() {
  let assert Ok(types.IndexArrayOfTables(count: 2, ..)) =
    get_index_path([KeySegment("a"), KeySegment("b"), KeySegment("g")])
}

pub fn nested_aot_a_b_g_h_i_j_test() {
  let assert Ok(types.IndexArrayOfTables(count: 2, ..)) =
    get_index_path([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("g"),
      KeySegment("h"),
      KeySegment("i"),
      KeySegment("j"),
    ])
}

pub fn sub_aot_scoped_per_entry_test() {
  let assert Ok(types.IndexArrayOfTables(count: 1, ..)) =
    index_path_in(per_entry_sub_aot_doc, [
      KeySegment("a"),
      KeySegment("b"),
      IndexSegment(0),
      KeySegment("d"),
    ])
  let assert Ok(types.IndexArrayOfTables(count: 1, ..)) =
    index_path_in(per_entry_sub_aot_doc, [
      KeySegment("a"),
      KeySegment("b"),
      IndexSegment(1),
      KeySegment("d"),
    ])
}

pub fn sub_aot_has_no_flat_path_test() {
  let assert Error(Nil) =
    index_path_in(per_entry_sub_aot_doc, [
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("d"),
    ])
}

pub fn scalar_x_in_a_b_c_d_e_test() {
  let assert Ok(types.IndexScalarValue(..)) =
    get_index_path([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("c"),
      KeySegment("d"),
      KeySegment("e"),
      KeySegment("x"),
    ])
}

pub fn keys_at_root_test() {
  assert Ok(["a"]) == get_keys("")
}

pub fn keys_at_a_test() {
  assert Ok(["b"]) == get_keys("a")
}

pub fn keys_at_a_b_test() {
  assert Ok(["c", "g"]) == get_keys("a.b")
}

pub fn keys_at_a_b_c_d_test() {
  assert Ok(["e", "f"]) == get_keys("a.b.c.d")
}

pub fn keys_at_a_b_c_d_e_test() {
  assert Ok(["x"]) == get_keys("a.b.c.d.e")
}

pub fn get_implicit_table_a_test() {
  assert Ok("table")
    == molt.parse(gnarly_doc)
    |> result.try(molt.get(_, path: "a"))
    |> result.map(value.type_of)
}

pub fn get_implicit_table_a_b_test() {
  assert Ok("table")
    == molt.parse(gnarly_doc)
    |> result.try(molt.get(_, path: "a.b"))
    |> result.map(value.type_of)
}

pub fn has_implicit_table_test() {
  let assert Ok(doc) = molt.parse(gnarly_doc)
  assert molt.has(doc:, path: "a")
  assert molt.has(doc:, path: "a.b")
  assert molt.has(doc:, path: "a.b.c")
  assert molt.has(doc:, path: "a.b.c.d")
  assert molt.has(doc:, path: "a.b.c.d.g") == False
  assert molt.has(doc:, path: "nonexistent") == False
}

pub fn get_aot_entry_test() {
  let assert Ok(doc) = molt.parse(gnarly_doc)
  let assert Ok(v) = molt.get(doc:, path: "a.b.g[0]")
  assert "table" == value.type_of(v)
  let assert Ok(z) = value.table_get_key(v, "z")
  let assert Ok(3) = value.unwrap_int(z)
}

pub fn get_aot_second_entry_test() {
  let assert Ok(doc) = molt.parse(gnarly_doc)
  let assert Ok(v) = molt.get(doc:, path: "a.b.g[1]")
  assert "table" == value.type_of(v)
  let assert Ok(z) = value.table_get_key(v, "z")
  let assert Ok(4) = value.unwrap_int(z)
}

pub fn move_keys_patched_vs_rebuilt_test() {
  let assert Ok(doc) =
    molt.parse("[source]\na = 1\nb = 2\nc = 3\n\n[dest]\nx = 10\n")
    |> result.try(molt.move_keys(
      _,
      from: "source",
      to: "dest",
      keys: ["a", "b", "c"],
      on_conflict: ops.OnConflictError,
    ))

  assert_index_matches(doc)
}

pub fn merge_patched_vs_rebuilt_test() {
  let assert Ok(doc) =
    molt.parse("[alpha]\none = 1\ntwo = 2\n\n[beta]\nthree = 3\n")
    |> result.try(molt.transfer(
      _,
      from: "alpha",
      to: "beta",
      on_conflict: ops.OnConflictError,
    ))

  assert_index_matches(doc)
}

pub fn ensure_and_merge_patched_vs_rebuilt_test() {
  let assert Ok(doc) =
    molt.parse("existing = true\n")
    |> result.try(
      molt.run(_, ops: [
        ops.EnsureExists(path: "new.nested", kind: types.Table),
        ops.MergeValues(
          path: "new.nested",
          entries: [
            #("key1", value.string("hello")),
            #("key2", value.int(42)),
          ],
          on_conflict: ops.OnConflictError,
        ),
      ]),
    )

  assert_index_matches(doc)
}

pub fn rename_patched_vs_rebuilt_test() {
  let assert Ok(doc) =
    molt.parse("[server]\nhost = \"localhost\"\nport = 8080\n")
    |> result.try(molt.rename(_, path: "server", to: "service"))

  assert_index_matches(doc)
}

pub fn multi_set_patched_vs_rebuilt_test() {
  let assert Ok(doc) =
    molt.parse("")
    |> result.try(
      molt.run(_, ops: [
        ops.Set(path: "a.b.c", value: value.string("deep")),
        ops.Set(path: "a.b.d", value: value.int(42)),
        ops.Set(path: "a.e", value: value.bool(True)),
        ops.Set(path: "x", value: value.string("top")),
      ]),
    )

  assert_index_matches(doc)
}

fn normalize_index(idx: DocumentIndex) -> DocumentIndex {
  dict.map_values(idx, fn(_key, entry) { normalize_entry(entry) })
}

fn sort(children: List(String)) -> List(String) {
  list.sort(children, by: string.compare)
}

fn normalize_entry(entry: IndexEntry) -> IndexEntry {
  case entry {
    types.IndexTable(children:) -> types.IndexTable(children: sort(children))
    types.IndexImplicitTable(children:) ->
      types.IndexImplicitTable(children: sort(children))
    types.IndexArrayOfTables(children:, ..) as v ->
      types.IndexArrayOfTables(..v, children: sort(children))
    types.IndexArrayOfTablesEntry(children:, ..) as v ->
      types.IndexArrayOfTablesEntry(..v, children: sort(children))
    _ -> entry
  }
}

fn assert_index_matches(doc) {
  let assert Ok(patched_idx) = index.get_index(doc)
  let assert Some(rebuilt_idx) = index.build_doc_index(doc)
  assert normalize_index(patched_idx) == normalize_index(rebuilt_idx)
}

pub fn build_index_test() {
  let assert Ok(doc) =
    molt.parse(
      "[server]\nhost = \"localhost\"\nport = 8080\n\n[database]\nurl = \"postgres://\"\n",
    )

  let assert Some(idx) = index.build_doc_index(doc)

  assert ["database", "database.url", "server", "server.host", "server.port"]
    == index_keys(idx)
}

pub fn build_index_array_of_tabless_test() {
  let assert Ok(doc) =
    molt.parse(
      "[[products]]\nname = \"Hammer\"\n\n[[products]]\nname = \"Nail\"\n",
    )

  let assert Some(idx) = index.build_doc_index(doc)

  assert [
      "products",
      "products[0]",
      "products[0].name",
      "products[1]",
      "products[1].name",
    ]
    == index_keys(idx)
}

pub fn build_index_dotted_keys_test() {
  let assert Ok(doc) = molt.parse("[server]\na.b.c = true\na.b.d = false\n")
  let assert Some(idx) = index.build_doc_index(doc)

  assert ["server", "server.a", "server.a.b", "server.a.b.c", "server.a.b.d"]
    == index_keys(idx)
}

fn index_keys(idx: DocumentIndex) -> List(String) {
  idx
  |> dict.keys()
  |> list.map(fn(k) { index.key_to_path(k) |> path.to_string })
  |> list.sort(by: string.compare)
}

fn get_index_path(path: Path) -> Result(IndexEntry, Nil) {
  index_path_in(gnarly_doc, path)
}

fn index_path_in(source: String, path: Path) -> Result(IndexEntry, Nil) {
  molt.parse(source)
  |> result.try(index.get_index)
  |> result.replace_error(Nil)
  |> result.try(index.get_path(_, path))
}

fn get_keys(path: String) -> Result(List(String), error.MoltError) {
  molt.parse(gnarly_doc)
  |> result.try(molt.keys(_, path:))
  |> result.map(list.sort(_, string.compare))
}

const gnarly_doc = "[a.b.c.d.e]
x = 1

[a.b.c.d.f]
y = 2

[[a.b.g]]
z = 3

[[a.b.g]]
z = 4

[[a.b.g.h.i.j]]
w = 5

[[a.b.g.h.i.j]]
w = 6

[a.b.g.h.i.j.k]
v = 7
"

const per_entry_sub_aot_doc = "[[a.b]]
c = 'A'

[[a.b.d]]
e = 1

[[a.b]]
c = 'B'

[[a.b.d]]
e = 2
"
