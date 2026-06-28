//// Lossy-regression tests: operations that previously went through
//// `value.from_cst → value.to_cst` discarded inner formatting, comments, and
//// numeric forms. Each test below pins down a piece of source detail that the
//// CST-native rewrites must preserve.

import gleam/result
import molt
import molt/ops
import molt/types
import molt/value

pub fn lossless_promote_implicit_preserves_key_order_test() {
  assert Ok("[a]\nh = 0xff\no = 0o755\nb = 0b1010\n")
    == molt.parse("a.h = 0xff\na.o = 0o755\na.b = 0b1010\n")
    |> result.try(molt.ensure_exists(_, "a", types.Table))
    |> result.map(molt.to_string)
}

pub fn lossless_promote_nested_implicit_preserves_order_test() {
  assert Ok("[a]\n\n[a.b]\nh = 0xff\no = 0o755\nk = 1\n")
    == molt.parse("[a]\nb.h = 0xff\nb.o = 0o755\nb.k = 1\n")
    |> result.try(molt.ensure_exists(_, "a.b", types.Table))
    |> result.map(molt.to_string)
}

pub fn lossless_append_preserves_element_comments_test() {
  // Layout-aware insertion: each new element (99, 3, 4) lands on its own
  // indented line ending in `,`, and the existing `# one` / `# two` comments
  // stay attached to their original elements.
  assert Ok("xs = [\n  1,  # one\n  99,\n  2,  # two\n  3,\n  4,\n]\n")
    == molt.parse("xs = [\n  1,  # one\n  2,  # two\n]\n")
    |> result.try(
      molt.run(_, [
        ops.Append("xs", value.int(3)),
        ops.Insert("xs", 1, value.int(99)),
        ops.Append("xs", value.int(4)),
      ]),
    )
    |> result.map(molt.to_string)
}

pub fn append_aot_with_descendant_keeps_sub_bound_to_prior_entry_test() {
  assert Ok(
      "[[items]]\nx = 1\n[items.sub]\ny = 2\n\n[[items]]\nx = 99\n[next]\nz = 3\n",
    )
    == molt.parse("[[items]]\nx = 1\n[items.sub]\ny = 2\n[next]\nz = 3\n")
    |> result.try(molt.append(_, "items", value.table([#("x", value.int(99))])))
    |> result.map(molt.to_string)
}

pub fn lossless_set_inline_table_key_preserves_formatting_test() {
  assert Ok("db = {host = \"localhost\", port = 5432}\n")
    == molt.parse("db = {host = \"localhost\", port = 3306}\n")
    |> result.try(molt.run(_, [ops.Set("db.port", value.int(5432))]))
    |> result.map(molt.to_string)
}

pub fn lossless_set_inline_table_key_preserves_comments_test() {
  let assert Ok(doc) =
    molt.parse(
      "db = {\n  # the host\n  host = \"localhost\",\n  # the port\n  port = 3306\n}\n",
    )
  assert Ok(
      "db = {\n  # the host\n  host = \"localhost\",\n  # the port\n  port = 5432\n}\n",
    )
    == molt.set_version(doc, to: molt.v1_1)
    |> molt.run([ops.Set("db.port", value.int(5432))])
    |> result.map(molt.to_string)
}

pub fn lossless_set_inline_array_element_preserves_formatting_test() {
  assert Ok("tags = [\"alpha\", \"bravo\", \"gamma\"]\n")
    == molt.parse("tags = [\"alpha\", \"beta\", \"gamma\"]\n")
    |> result.try(molt.run(_, [ops.Set("tags[1]", value.string("bravo"))]))
    |> result.map(molt.to_string)
}

pub fn lossless_set_inline_array_element_preserves_comments_test() {
  assert Ok(
      "tags = [\n  # first\n  \"alpha\",\n  # second\n  \"bravo\",\n  # third\n  \"gamma\"\n]\n",
    )
    == molt.parse(
      "tags = [\n  # first\n  \"alpha\",\n  # second\n  \"beta\",\n  # third\n  \"gamma\"\n]\n",
    )
    |> result.try(molt.run(_, [ops.Set("tags[1]", value.string("bravo"))]))
    |> result.map(molt.to_string)
}

pub fn lossless_remove_inline_array_element_preserves_formatting_test() {
  assert Ok("nums = [1, 3]\n")
    == molt.parse("nums = [1, 2, 3]\n")
    |> result.try(molt.run(_, [ops.Remove("nums[1]")]))
    |> result.map(molt.to_string)
}

pub fn lossless_remove_inline_array_element_preserves_comments_test() {
  assert Ok("tags = [\n  # keep\n  \"alpha\",\n  # keep\n  \"gamma\"\n]\n")
    == molt.parse(
      "tags = [\n  # keep\n  \"alpha\",\n  # remove\n  \"beta\",\n  # keep\n  \"gamma\"\n]\n",
    )
    |> result.try(molt.run(_, [ops.Remove("tags[1]")]))
    |> result.map(molt.to_string)
}

pub fn lossless_update_inline_table_key_preserves_formatting_test() {
  assert Ok("server = { host = \"localhost\",  port = 8081 }\n")
    == molt.parse("server = { host = \"localhost\",  port = 8080 }\n")
    |> result.try(
      molt.run(_, [
        ops.Update("server.port", fn(v) {
          case value.unwrap_int(v) {
            Ok(n) -> Ok(value.int(n + 1))
            Error(e) -> Error(e)
          }
        }),
      ]),
    )
    |> result.map(molt.to_string)
}

pub fn lossless_set_nested_inline_array_table_array_test() {
  assert Ok("data = [{tags = [\"a\", \"b\"]}, {tags = [\"c\", \"z\"]}]\n")
    == molt.parse("data = [{tags = [\"a\", \"b\"]}, {tags = [\"c\", \"d\"]}]\n")
    |> result.try(molt.run(_, [ops.Set("data[1].tags[1]", value.string("z"))]))
    |> result.map(molt.to_string)
}

pub fn lossless_set_array_element_preserves_sibling_comment_test() {
  assert Ok("arr = [\n  9,\n  # about two\n  2,\n  3,\n]\n")
    == molt.parse("arr = [\n  1,\n  # about two\n  2,\n  3,\n]\n")
    |> result.try(molt.run(_, [ops.Set("arr[0]", value.int(9))]))
    |> result.map(molt.to_string)
}
