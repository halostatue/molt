//// Round-trip adversarial tests for molt operations.
////
//// Each test asserts that parse(src) → run(ops) → to_string → parse produces
//// a document with no validation errors. This is the contract operations must
//// satisfy: they cannot produce TOML that the validator rejects.
////
//// When an op should refuse a request, the contract is "error at op-time OR
//// produce valid output, never produce invalid output." Use `op_safe` for
//// that shape; use `round_trip_ok` when success is mandatory.

import gleam/option.{None}
import molt
import molt/error
import molt/ops
import molt/types
import molt/value

const a_canonical = "gleam = 1\na.b.q = 42\n[a.b.c]\nd = 67\n"

pub fn a_ensure_exists_on_implicit_round_trips_test() {
  round_trip_ok(a_canonical, [ops.EnsureExists("a.b", types.Table)])
}

pub fn a_merge_concrete_into_implicit_round_trips_test() {
  round_trip_ok(a_canonical, [
    ops.Transfer(from: "a.b.c", to: "a.b", on_conflict: ops.OnConflictError),
  ])
}

pub fn a_move_root_into_implicit_descendant_round_trips_test() {
  round_trip_ok(a_canonical, [ops.Move(from: "gleam", to: "a.b.z")])
}

pub fn a_move_keys_concrete_to_implicit_round_trips_test() {
  round_trip_ok(a_canonical, [
    ops.MoveKeys(
      from: "a.b.c",
      to: "a.b",
      keys: ["d"],
      on_conflict: ops.OnConflictError,
    ),
  ])
}

pub fn a_rename_implicit_table_round_trips_test() {
  round_trip_ok(a_canonical, [ops.Rename(path: "a.b", to: "renamed")])
}

pub fn a_insert_key_on_implicit_round_trips_test() {
  round_trip_ok(a_canonical, [
    ops.InsertKey(path: "a.b", before: "q", key: "k", value: value.int(7)),
  ])
}

pub fn b_set_through_scalar_is_safe_test() {
  op_safe("a.b = \"scalar\"\n", [ops.Set("a.b.c", value.int(2))])
}

pub fn b_set_into_inline_table_is_safe_test() {
  op_safe("a = { x = 1 }\n", [ops.Set("a.y", value.int(2))])
}

pub fn b_set_replacing_inline_table_with_nested_path_is_safe_test() {
  op_safe("a = { x = { y = 1 } }\n", [ops.Set("a.x.z", value.int(2))])
}

pub fn b_set_into_array_of_tables_entry_round_trips_test() {
  let src = "[[items]]\nx = 1\n[[items]]\nx = 2\n"
  round_trip_ok(src, [ops.Set("items[0].y", value.int(3))])
}

pub fn b_ensure_exists_inside_aot_entry_round_trips_test() {
  let src = "[[items]]\nx = 1\n"
  round_trip_ok(src, [
    ops.EnsureExists("items[0].nested", types.Table),
    ops.MergeValues(
      "items[0].nested",
      [#("k", value.int(9))],
      ops.OnConflictError,
    ),
  ])
}

pub fn b_append_to_table_errors_cleanly_test() {
  let assert Ok(d) = molt.parse("[a]\nx = 1\n")
  let assert Error(error.TypeMismatch(..)) = molt.append(d, "a", value.int(2))
}

pub fn c_ensure_inline_then_set_round_trips_test() {
  let src = "a = { x = 1 }\n"
  op_safe(src, [
    ops.EnsureExists("a", types.Table),
    ops.Set("a.y", value.int(2)),
  ])
}

pub fn c_move_then_rename_round_trips_test() {
  let src = "gleam = 1\na.b.q = 42\n[a.b.c]\nd = 67\n"
  round_trip_ok(src, [
    ops.Move(from: "a.b.c", to: "moved"),
    ops.Rename(path: "moved", to: "final"),
  ])
}

pub fn c_remove_implicit_then_ensure_exists_round_trips_test() {
  let src = "gleam = 1\na.b.q = 42\n[a.b.c]\nd = 67\n"
  round_trip_ok(src, [
    ops.Remove("a.b"),
    ops.EnsureExists("a.b", types.Table),
    ops.MergeValues("a.b", [#("fresh", value.int(1))], ops.OnConflictError),
  ])
}

pub fn c_set_sibling_then_remove_original_round_trips_test() {
  let src = "gleam = 1\na.b.q = 42\n[a.b.c]\nd = 67\n"
  round_trip_ok(src, [
    ops.Set("a.b.f", value.int(99)),
    ops.Remove("a.b.q"),
  ])
}

pub fn c_create_then_merge_round_trips_test() {
  let src = "[src]\nx = 1\ny = 2\n"
  round_trip_ok(src, [
    ops.EnsureExists("dst", types.Table),
    ops.Transfer(from: "src", to: "dst", on_conflict: ops.OnConflictError),
  ])
}

pub fn d_promote_implicit_with_multiple_dotted_siblings_test() {
  let src = "a.b.q = 1\na.b.r = 2\n"
  round_trip_ok(src, [ops.EnsureExists("a.b", types.Table)])
}

pub fn d_promote_implicit_with_nested_dotted_sibling_test() {
  let src = "a.b.q = 1\n[a.b.c]\nd = 2\n"
  round_trip_ok(src, [ops.EnsureExists("a.b", types.Table)])
}

pub fn d_promote_implicit_inside_section_test() {
  let src = "[outer]\na.b.q = 1\n"
  round_trip_ok(src, [ops.EnsureExists("outer.a.b", types.Table)])
}

pub fn d_promote_implicit_inside_aot_entry_test() {
  let src = "[[items]]\ndeep.x = 1\n"
  round_trip_ok(src, [ops.EnsureExists("items[0].deep", types.Table)])
}

pub fn d_promote_implicit_with_array_value_sibling_test() {
  let src = "a.b.q = [1, 2, 3]\n"
  round_trip_ok(src, [ops.EnsureExists("a.b", types.Table)])
}

fn identity_with(v: value.Value) -> Result(value.Value, _) {
  Ok(v)
}

pub fn e_update_on_scalar_round_trips_test() {
  round_trip_ok("x = 1\n", [ops.Update("x", identity_with)])
}

pub fn e_update_on_inline_table_round_trips_test() {
  round_trip_ok("a = { x = 1 }\n", [ops.Update("a", identity_with)])
}

pub fn e_update_on_array_value_round_trips_test() {
  round_trip_ok("xs = [1, 2, 3]\n", [ops.Update("xs", identity_with)])
}

pub fn e_update_on_implicit_table_refuses_test() {
  op_refuses("a.b.q = 1\n", [ops.Update("a.b", identity_with)], type_mismatch)
}

pub fn e_update_on_explicit_section_refuses_test() {
  op_refuses("[a]\nx = 1\n", [ops.Update("a", identity_with)], type_mismatch)
}

pub fn e_update_on_aot_root_refuses_test() {
  op_refuses(
    "[[items]]\nx = 1\n",
    [ops.Update("items", identity_with)],
    type_mismatch,
  )
}

const e_comments = ops.Comments(leading: ["# leading"], trailing: None)

pub fn e_set_comments_on_plain_key_round_trips_test() {
  round_trip_ok("x = 1\n", [ops.SetComments("x", e_comments)])
}

pub fn e_set_comments_on_dotted_under_implicit_round_trips_test() {
  round_trip_ok("a.b.q = 1\n", [ops.SetComments("a.b.q", e_comments)])
}

pub fn e_set_comments_on_implicit_table_is_safe_test() {
  op_safe("a.b.q = 1\n", [ops.SetComments("a.b", e_comments)])
}

pub fn e_set_comments_on_aot_entry_round_trips_test() {
  round_trip_ok("[[items]]\nx = 1\n", [
    ops.SetComments("items[0]", e_comments),
  ])
}

pub fn e_set_comments_on_explicit_section_round_trips_test() {
  round_trip_ok("[a]\nx = 1\n", [ops.SetComments("a", e_comments)])
}

pub fn e_move_comments_between_keys_round_trips_test() {
  let src = "# from comment\nx = 1\ny = 2\n"
  round_trip_ok(src, [ops.MoveComments(from: "x", to: "y")])
}

pub fn e_move_comments_from_implicit_is_safe_test() {
  op_safe("a.b.q = 1\ny = 2\n", [ops.MoveComments(from: "a.b", to: "y")])
}

pub fn e_replace_scalar_with_scalar_round_trips_test() {
  round_trip_ok("x = 1\n", [ops.Place("x", value.int(2))])
}

pub fn e_replace_inline_table_with_scalar_round_trips_test() {
  round_trip_ok("a = { x = 1 }\n", [ops.Place("a", value.int(2))])
}

pub fn e_replace_explicit_section_with_scalar_round_trips_test() {
  round_trip_ok("[a]\nx = 1\n", [ops.Place("a", value.int(2))])
}

pub fn e_replace_implicit_table_with_scalar_round_trips_test() {
  round_trip_ok("a.b.q = 1\n", [ops.Place("a.b", value.int(2))])
}

pub fn e_replace_scalar_with_table_value_round_trips_test() {
  round_trip_ok("a = 1\n", [
    ops.Place("a", value.table([#("x", value.int(2))])),
  ])
}

pub fn e_append_to_array_round_trips_test() {
  round_trip_ok("xs = [1, 2, 3]\n", [ops.Append("xs", value.int(4))])
}

pub fn e_append_to_aot_round_trips_test() {
  let src = "[[items]]\nx = 1\n"
  round_trip_ok(src, [
    ops.Append("items", value.table([#("x", value.int(2))])),
  ])
}

pub fn e_append_to_explicit_section_refuses_test() {
  op_refuses("[a]\nx = 1\n", [ops.Append("a", value.int(2))], type_mismatch)
}

pub fn e_append_to_implicit_table_refuses_test() {
  op_refuses("a.b.q = 1\n", [ops.Append("a.b", value.int(2))], type_mismatch)
}

pub fn e_append_to_scalar_refuses_test() {
  op_refuses("x = 1\n", [ops.Append("x", value.int(2))], type_mismatch)
}

pub fn e_insert_at_array_start_round_trips_test() {
  round_trip_ok("xs = [1, 2, 3]\n", [ops.Insert("xs", 0, value.int(0))])
}

pub fn e_insert_at_array_end_round_trips_test() {
  round_trip_ok("xs = [1, 2, 3]\n", [ops.Insert("xs", 3, value.int(4))])
}

pub fn e_insert_past_array_end_refuses_test() {
  op_refuses(
    "xs = [1, 2, 3]\n",
    [ops.Insert("xs", 99, value.int(0))],
    out_of_range,
  )
}

pub fn e_insert_at_negative_in_bounds_round_trips_test() {
  round_trip_ok("xs = [1, 2, 3]\n", [ops.Insert("xs", -1, value.int(99))])
}

pub fn e_insert_past_array_start_negative_refuses_test() {
  op_refuses(
    "xs = [1, 2, 3]\n",
    [ops.Insert("xs", -10, value.int(0))],
    out_of_range,
  )
}

pub fn e_insert_into_aot_round_trips_test() {
  let src = "[[items]]\nx = 1\n[[items]]\nx = 2\n"
  round_trip_ok(src, [
    ops.Insert("items", 0, value.table([#("x", value.int(0))])),
  ])
}

pub fn e_insert_key_before_existing_round_trips_test() {
  let src = "[a]\nx = 1\ny = 2\n"
  round_trip_ok(src, [
    ops.InsertKey(path: "a", before: "y", key: "new", value: value.int(99)),
  ])
}

pub fn e_insert_key_before_missing_appends_test() {
  let src = "[a]\nx = 1\n"
  round_trip_ok(src, [
    ops.InsertKey(path: "a", before: "missing", key: "k", value: value.int(1)),
  ])
}

pub fn e_insert_key_into_aot_entry_round_trips_test() {
  let src = "[[items]]\nx = 1\ny = 2\n"
  op_safe(src, [
    ops.InsertKey(
      path: "items[0]",
      before: "y",
      key: "new",
      value: value.int(99),
    ),
  ])
}

pub fn f_set_into_aot_entry_with_dotted_path_round_trips_test() {
  let src = "[[items]]\nx = 1\n"
  round_trip_ok(src, [ops.Set("items[0].nested.deep", value.int(7))])
}

pub fn f_set_replacing_aot_entry_scalar_round_trips_test() {
  let src = "[[items]]\nx = 1\n"
  round_trip_ok(src, [ops.Set("items[0].x", value.int(99))])
}

pub fn f_move_from_aot_entry_to_root_round_trips_test() {
  let src = "[[items]]\nx = 1\ny = 2\n"
  round_trip_ok(src, [ops.Move(from: "items[0].y", to: "lifted")])
}

pub fn f_move_inline_table_descendant_is_safe_test() {
  op_safe("a = { x = 1, y = 2 }\n", [ops.Move(from: "a.y", to: "lifted")])
}

pub fn f_remove_aot_entry_round_trips_test() {
  let src = "[[items]]\nx = 1\n[[items]]\nx = 2\n"
  round_trip_ok(src, [ops.Remove("items[0]")])
}

pub fn f_remove_dotted_descendant_round_trips_test() {
  let src = "a.b.q = 1\na.b.r = 2\n"
  round_trip_ok(src, [ops.Remove("a.b.q")])
}

pub fn f_remove_inline_table_key_is_safe_test() {
  op_safe("a = { x = 1, y = 2 }\n", [ops.Remove("a.x")])
}

pub fn f_set_on_aot_root_refuses_test() {
  op_refuses(
    "[[items]]\nx = 1\n",
    [ops.Set("items", value.int(2))],
    type_mismatch,
  )
}

fn round_trip_ok(src: String, op_list: List(ops.Operation)) {
  let assert Ok(d1) = molt.parse(src)
  assert !molt.has_errors(d1)
  let assert Ok(d2) = molt.run(d1, op_list)
  let out = molt.to_string(d2)
  let assert Ok(d3) = molt.parse(out)
  assert !molt.has_errors(d3)
}

fn op_safe(src: String, op_list: List(ops.Operation)) {
  let assert Ok(d1) = molt.parse(src)
  assert !molt.has_errors(d1)
  case molt.run(d1, op_list) {
    Error(_) -> Nil
    Ok(d2) -> {
      let out = molt.to_string(d2)
      let assert Ok(d3) = molt.parse(out)
      assert !molt.has_errors(d3)
    }
  }
}

fn op_refuses(
  src: String,
  op_list: List(ops.Operation),
  expect: fn(error.MoltError) -> Bool,
) {
  let assert Ok(d) = molt.parse(src)
  assert !molt.has_errors(d)
  let assert Error(e) = molt.run(d, op_list)
  assert expect(e)
}

fn type_mismatch(e: error.MoltError) -> Bool {
  case e {
    error.TypeMismatch(..) -> True
    _ -> False
  }
}

fn out_of_range(e: error.MoltError) -> Bool {
  case e {
    error.IndexOutOfRange(..) -> True
    _ -> False
  }
}
