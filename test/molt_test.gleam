//// Tests for the main `molt` module: the public API surface (`new`, `parse`,
//// `parse_bits`, `move`, `length`, `remove`, `transfer`, `insert`,
//// `insert_key`, `update`, `place`, `ensure_exists` + `merge_values`,
//// `has_errors` / `error_count` / `document_errors`, `set_version`,
//// `to_normalized_string`).
////
//// Topic-specific suites live elsewhere: comment ops in comments_test,
//// normalization in normalize_test, operation effects in operations_test, and
//// implicit-table operation variants in implicit_table_ops_test.

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import molt
import molt/error.{InvalidOperation, NotFound}
import molt/ops.{Comments}
import molt/types
import molt/value

pub fn main() {
  gleeunit.main()
}

pub fn new_creates_empty_document_test() {
  assert "" == molt.new() |> molt.to_string
}

pub fn move_test() {
  let assert Ok(doc) = molt.parse("[a]\nx = 1\n\n[b]\ny = 2\n")
  let assert Ok(doc2) = molt.run(doc:, ops: [ops.Move(from: "a.x", to: "b.x")])
  let result = molt.to_string(doc2)
  let assert True = string.contains(result, "x = 1")
}

pub fn move_dotted_key_to_new_root_path_test() {
  let assert Ok(doc) = molt.parse("gleam = 1\na.b.q = 42\n[a.b.c]\nd = 67\n")
  let output =
    doc
    |> molt.move("a.b.q", "abq.left_turn")
    |> result.try(molt.move(_, "a.b", "pismo.beach"))
    |> result.map(molt.to_string)
    |> result.unwrap("<error>")

  assert output == "gleam = 1\nabq.left_turn = 42\n[pismo.beach.c]\nd = 67\n"
}

pub fn length_test() {
  let assert Ok(doc) = molt.parse("[config]\ntags = [\"a\", \"b\", \"c\"]\n")
  let assert Ok(3) = molt.length(doc:, path: "config.tags")
}

pub fn length_aot_path_test() {
  let toml =
    "[[a]]\n[[a.b]]\nc = [10, 20]\n[[a.b]]\nc = [30, 40, 50]\n[[a]]\n[[a.b]]\nc = [1]\n[[a.b]]\nc = [2, 3, 4, 5]\n"
  let assert Ok(doc) = molt.parse(toml)
  let assert Ok(3) = molt.length(doc:, path: "a[0].b[1].c")
  let assert Ok(4) = molt.length(doc:, path: "a[1].b[1].c")
}

pub fn length_inline_array_element_test() {
  let assert Ok(doc) = molt.parse("[a]\nb = [[1,2],[3,4,5]]\n")
  let assert Ok(2) = molt.length(doc:, path: "a.b")
  let assert Ok(2) = molt.length(doc:, path: "a.b[0]")
  let assert Ok(3) = molt.length(doc:, path: "a.b[1]")
  let assert Ok(3) = molt.length(doc:, path: "a.b[-1]")
}

pub fn ensure_exists_in_aot_scope_targets_correct_entry_test() {
  let toml = "[[items]]\nx = 1\n[items.nested]\nk = 10\n[[items]]\nx = 2\n"
  let assert Ok(doc) = molt.parse(toml)
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.EnsureExists("items[1].nested", types.Table),
      ops.MergeValues(
        "items[1].nested",
        [#("k", value.int(99))],
        ops.OnConflictError,
      ),
    ])
  let out = molt.to_string(doc2)
  let assert Ok(v0) = molt.get(doc2, "items[0].nested.k")
  let assert Ok(v1) = molt.get(doc2, "items[1].nested.k")
  let assert Ok(10) = value.unwrap_int(v0)
  let assert Ok(99) = value.unwrap_int(v1)
  let assert True = string.contains(out, "x = 1")
  let assert True = string.contains(out, "x = 2")
}

pub fn ensure_exists_in_aot_scope_deep_kv_test() {
  let toml = "[[items]]\nx = 1\n"
  let assert Ok(doc) = molt.parse(toml)
  let assert Ok(doc2) =
    molt.run(doc:, ops: [
      ops.EnsureExists("items[0].nested", types.Table),
      ops.MergeValues(
        "items[0].nested",
        [#("k", value.int(42))],
        ops.OnConflictError,
      ),
    ])
  let assert Ok(v) = molt.get(doc2, "items[0].nested.k")
  let assert Ok(42) = value.unwrap_int(v)
}

pub fn parse_test() {
  let assert Ok(doc) = molt.parse("x = 1\n")
  assert molt.has(doc, "x")
  let assert Ok(v) = molt.get(doc, "x")
  let assert Ok(1) = value.unwrap_int(v)
}

pub fn parse_bits_test() {
  let assert Ok(doc) = molt.parse_bits(bit_array.from_string("x = 1\n"))
  assert molt.has(doc, "x")
  let assert Ok(v) = molt.get(doc, "x")
  let assert Ok(1) = value.unwrap_int(v)
}

pub fn version_controlled_output_test() {
  let v1_1 = "server = {\n  port = 8080, # Comment on inline table \n}"
  let v1_0 = "server = { port = 8080 }"
  let assert Ok(doc) = molt.parse(v1_1)

  assert v1_1
    == molt.set_version(doc:, to: molt.v1_1)
    |> molt.to_string

  assert v1_0
    == molt.set_version(doc:, to: molt.v1_0)
    |> molt.to_string
}

pub fn validate_test() {
  let assert Ok(doc) = molt.parse("x = 1\n")
  assert !molt.has_errors(doc)
  assert molt.error_count(doc) == 0
  assert molt.document_errors(doc) == []
}

pub fn to_normalized_string_test() {
  let assert Ok(doc) = molt.parse("[server]\nport   =   8080\n")
  let result = molt.to_normalized_string(doc:)
  let assert True = string.contains(result, "port = 8080")
}

pub fn describe_error_test() {
  let msg = error.describe_error(error.InvalidPath("bad path"))
  assert msg == "Invalid path: bad path"
}

const aot_doc = "[[items]]\nname = \"a\"\n\n[[items]]\nname = \"b\"\n"

pub fn remove_deletes_key_test() {
  assert Ok("y = 2\n")
    == molt.parse("x = 1\ny = 2\n")
    |> result.try(molt.remove(doc: _, path: "x"))
    |> result.map(molt.to_string)
}

pub fn remove_deletes_table_test() {
  assert Ok("[b]\ny = 2\n")
    == molt.parse("[a]\nx = 1\n[b]\ny = 2\n")
    |> result.try(molt.remove(doc: _, path: "a"))
    |> result.map(molt.to_string)
}

pub fn remove_deletes_array_of_tables_test() {
  assert Ok("")
    == molt.parse(aot_doc)
    |> result.try(molt.remove(doc: _, path: "items"))
    |> result.map(molt.to_string)
}

pub fn remove_deletes_aot_entry_test() {
  assert Ok("[[items]]\nname = \"b\"\n")
    == molt.parse(aot_doc)
    |> result.try(molt.remove(doc: _, path: "items[0]"))
    |> result.map(molt.to_string)
}

pub fn remove_deletes_key_in_aot_entry_test() {
  assert Ok("[[items]]\n\n[[items]]\nname = \"b\"\n")
    == molt.parse(aot_doc)
    |> result.try(molt.remove(doc: _, path: "items[0].name"))
    |> result.map(molt.to_string)
}

pub fn remove_deletes_array_element_test() {
  assert Ok("arr = [1, 3]\n")
    == molt.parse("arr = [1, 2, 3]\n")
    |> result.try(molt.remove(doc: _, path: "arr[1]"))
    |> result.map(molt.to_string)
}

pub fn transfer_combines_tables_test() {
  assert Ok("[b]\ny = 2\nx = 1\n")
    == molt.parse("[a]\nx = 1\n[b]\ny = 2\n")
    |> result.try(molt.transfer(
      doc: _,
      from: "a",
      to: "b",
      on_conflict: ops.OnConflictSkip,
    ))
    |> result.map(molt.to_string)
}

pub fn ensure_exists_then_merge_values_adds_section_test() {
  assert Ok("[server]\nport = 8080\n")
    == molt.parse("")
    |> result.try(molt.ensure_exists(doc: _, path: "server", kind: types.Table))
    |> result.try(molt.merge_values(
      _,
      "server",
      [#("port", value.int(8080))],
      ops.OnConflictError,
    ))
    |> result.map(molt.to_string)
}

pub fn ensure_exists_then_fill_first_aot_entry_test() {
  let assert Ok(doc) = molt.parse("")
  let assert Ok(doc1) =
    molt.ensure_exists(doc:, path: "items", kind: types.ArrayOfTables)
  let assert Ok(doc2) =
    molt.merge_values(
      doc1,
      "items[0]",
      [#("name", value.string("first"))],
      ops.OnConflictError,
    )
  let assert Ok(v) = molt.get(doc2, "items[0].name")
  let assert Ok("first") = value.unwrap_string(v)
}

pub fn insert_adds_element_at_index_test() {
  assert Ok("arr = [1, 2, 3]\n")
    == molt.parse("arr = [1, 3]\n")
    |> result.try(molt.insert(
      doc: _,
      path: "arr",
      before: 1,
      value: value.int(2),
    ))
    |> result.map(molt.to_string)
}

pub fn insert_key_inserts_before_sibling_test() {
  assert Ok("[t]\na = 1\nb = 2\nc = 3\n")
    == molt.parse("[t]\na = 1\nc = 3\n")
    |> result.try(molt.insert_key(
      doc: _,
      path: "t",
      before: "c",
      key: "b",
      value: value.int(2),
    ))
    |> result.map(molt.to_string)
}

pub fn update_transforms_value_test() {
  assert Ok("x = 99\n")
    == molt.parse("x = 1\n")
    |> result.try(
      molt.update(doc: _, path: "x", with: fn(_) { Ok(value.int(99)) }),
    )
    |> result.map(molt.to_string)
}

pub fn place_scalar_with_scalar_test() {
  assert Ok("x = \"hello\"\n")
    == molt.parse("x = 1\n")
    |> result.try(molt.place(doc: _, path: "x", value: value.string("hello")))
    |> result.map(molt.to_string)
}

pub fn place_table_section_with_scalar_test() {
  assert Ok("t = 99\n")
    == molt.parse("[t]\nk = 1\n")
    |> result.try(molt.place(doc: _, path: "t", value: value.int(99)))
    |> result.map(molt.to_string)
}

pub fn place_scalar_with_table_section_test() {
  assert Ok("[server]\nport = 8080\n")
    == molt.parse("server = \"old\"\n")
    |> result.try(molt.place(
      doc: _,
      path: "server",
      value: value.from_table_entries([#("port", value.int(8080))]),
    ))
    |> result.map(molt.to_string)
}

pub fn place_nonexistent_path_creates_test() {
  assert Ok("x = 42\n")
    == molt.parse("")
    |> result.try(molt.place(doc: _, path: "x", value: value.int(42)))
    |> result.map(molt.to_string)
}

pub fn place_table_over_nested_scalar_test() {
  let assert Ok(doc) = molt.parse("[a]\nb = 1\n")
  let assert Ok(doc2) =
    molt.place(doc, "a.b", value.from_table_entries([#("c", value.int(2))]))
  assert molt.to_normalized_string(doc2) == "[a]\n\n[a.b]\nc = 2\n"
}

pub fn place_aot_over_table_test() {
  let assert Ok(doc) = molt.parse("[a.b]\nx = 1\n")
  let assert Ok(aot_doc) =
    value.from_array_of_tables([
      value.from_table_entries([#("y", value.int(2))]),
    ])
  let assert Ok(doc2) = molt.place(doc, "a.b", aot_doc)
  assert molt.to_normalized_string(doc2) == "[[a.b]]\ny = 2\n"
}

pub fn set_scalar_over_table_rejected_test() {
  let assert Ok(doc) = molt.parse("[a.b]\nx = 1\n")
  let assert Error(error.TypeMismatch(
    path: Some("a.b"),
    expected: "scalar or array value",
    got: "table",
  )) = molt.set(doc, "a.b", value.int(5))
}

pub fn set_comments_attaches_leading_comment_test() {
  assert Ok("# hello\nx = 1\n")
    == molt.parse("x = 1\n")
    |> result.try(molt.set_comments(
      doc: _,
      path: "x",
      comments: Comments(leading: ["hello"], trailing: None),
    ))
    |> result.map(molt.to_string)
}

pub fn move_comments_transfers_comment_test() {
  assert Ok("x = 1\n# note\ny = 2\n")
    == molt.parse("# note\nx = 1\ny = 2\n")
    |> result.try(molt.move_comments(doc: _, from: "x", to: "y"))
    |> result.map(molt.to_string)
}

pub fn get_comments_reads_leading_and_trailing_test() {
  assert Ok(Comments(leading: ["# a", "# b"], trailing: Some("# inline")))
    == molt.parse("# a\n# b\nx = 1 # inline\n")
    |> result.try(molt.get_comments(doc: _, path: "x"))
}

pub fn get_comments_empty_when_none_test() {
  assert Ok(Comments(leading: [], trailing: None))
    == molt.parse("x = 1\n")
    |> result.try(molt.get_comments(doc: _, path: "x"))
}

pub fn get_comments_missing_path_errors_test() {
  assert Error(NotFound("nope", "nope"))
    == molt.parse("x = 1\n")
    |> result.try(molt.get_comments(doc: _, path: "nope"))
}

pub fn get_comments_rejects_implicit_table_test() {
  assert Error(InvalidOperation(
      "get_comments",
      Some("implicit tables have no concrete node"),
    ))
    == molt.parse("[a.b]\nx = 1\n")
    |> result.try(molt.get_comments(doc: _, path: "a"))
}

pub fn get_comments_reads_table_header_leading_and_trailing_test() {
  assert Ok(Comments(leading: ["#a", "# b"], trailing: Some("# prod")))
    == molt.parse("#a\n# b\n[server] # prod\nport = 8080\n")
    |> result.try(molt.get_comments(doc: _, path: "server"))
}

pub fn set_comments_replaces_parsed_trailing_without_duplication_test() {
  assert Ok("x = 1 # new\n")
    == molt.parse("x = 1 # old\n")
    |> result.try(molt.set_comments(
      doc: _,
      path: "x",
      comments: Comments(leading: [], trailing: Some("# new")),
    ))
    |> result.map(molt.to_string)
}

pub fn set_comments_clears_parsed_trailing_test() {
  assert Ok("x = 1\n")
    == molt.parse("x = 1 # old\n")
    |> result.try(molt.set_comments(
      doc: _,
      path: "x",
      comments: Comments(leading: [], trailing: None),
    ))
    |> result.map(molt.to_string)
}

// --- Document-level comments: the Head and Tail tombstones ---
// Document-level comments belong to the file, not to any statement. They are
// addressed by slot (`Head` / `Tail`) through `get_document_comments` /
// `set_document_comments`, never by path. The path-based comment API rejects
// the empty path.

pub fn set_head_comment_on_empty_doc_emits_and_reads_back_test() {
  let doc = molt.set_document_comments(molt.new(), molt.Header, ["head"])
  // Stored on Root trivia: emits as the sole document content.
  assert "# head\n" == molt.to_string(doc)
  // And reads back through the same slot.
  assert ["# head"] == molt.get_document_comments(doc, molt.Header)
}

pub fn parsed_head_comment_with_no_blank_belongs_to_first_node_test() {
  // A comment directly above the first statement (no separating blank) is THAT
  // node's leading comment, not a document-head comment.
  let assert Ok(doc) = molt.parse("# header line\nx = 1\n")
  assert [] == molt.get_document_comments(doc, molt.Header)
  assert Ok(Comments(leading: ["# header line"], trailing: None))
    == molt.get_comments(doc:, path: "x")
}

pub fn parsed_blank_separated_head_block_is_a_document_head_comment_test() {
  // A leading comment block separated from the content by a blank line is a
  // document-head comment: it moves to the Head slot, and only the comments
  // after the blank stay on the first node. Pure redistribution — still
  // round-trips byte-for-byte.
  let assert Ok(doc) = molt.parse("# a\n# b\n\n# c\n[q]\nr = 5\n")
  assert ["# a", "# b"] == molt.get_document_comments(doc, molt.Header)
  assert Ok(Comments(leading: ["# c"], trailing: None))
    == molt.get_comments(doc:, path: "q")
  assert "# a\n# b\n\n# c\n[q]\nr = 5\n" == molt.to_string(doc)
}

pub fn parsed_comment_only_doc_keeps_head_comments_on_root_test() {
  // With no statement to attach to, a comment-only document keeps everything on
  // the Head slot (no split), readable and editable, round-tripping exactly.
  let assert Ok(doc) = molt.parse("# c1\n# c2\n")
  assert ["# c1", "# c2"] == molt.get_document_comments(doc, molt.Header)
  assert "# c1\n# c2\n" == molt.to_string(doc)

  let doc = molt.set_document_comments(doc, molt.Header, ["replaced"])
  assert "# replaced\n" == molt.to_string(doc)
}

pub fn trailing_comment_after_content_is_a_document_tail_comment_test() {
  // A comment after the last node is the document tail: it round-trips in place,
  // is NOT a head comment, and is readable/editable through the Tail slot.
  let assert Ok(doc) = molt.parse("a = 1\n# trailing\n")
  assert "a = 1\n# trailing\n" == molt.to_string(doc)
  assert [] == molt.get_document_comments(doc, molt.Header)
  assert ["# trailing"] == molt.get_document_comments(doc, molt.Trailer)
}

pub fn set_head_comment_is_not_aliased_to_first_node_test() {
  // Setting the head on a doc whose first node already has a comment adds a
  // DISTINCT head comment; it does not replace or touch the node's comment.
  let assert Ok(doc) = molt.parse("# comment\na = 5\n")
  let doc = molt.set_document_comments(doc, molt.Header, ["other"])
  // The head comment is blank-separated from the content so it round-trips as a
  // head comment; `# comment` stays the first node's own (adjacent) comment.
  assert "# other\n\n# comment\na = 5\n" == molt.to_string(doc)
  assert ["# other"] == molt.get_document_comments(doc, molt.Header)
  assert Ok(Comments(leading: ["# comment"], trailing: None))
    == molt.get_comments(doc:, path: "a")
}

pub fn head_comment_stays_on_root_when_table_added_test() {
  // Adding a first `[table]` does NOT migrate the head onto it. The comment
  // still renders at the top (Root trivia emits first) but stays Root-resident.
  let doc = molt.set_document_comments(molt.new(), molt.Header, ["head"])
  let assert Ok(doc) =
    molt.ensure_exists(doc:, path: "server", kind: types.Table)
  assert "# head\n\n[server]\n" == molt.to_string(doc)
  assert ["# head"] == molt.get_document_comments(doc, molt.Header)
  assert Ok(Comments(leading: [], trailing: None))
    == molt.get_comments(doc:, path: "server")
}

pub fn head_comment_stays_on_root_when_aot_and_kv_added_test() {
  let aot = molt.set_document_comments(molt.new(), molt.Header, ["head"])
  let assert Ok(aot) =
    molt.ensure_exists(doc: aot, path: "plugins", kind: types.ArrayOfTables)
  assert "# head\n\n[[plugins]]\n" == molt.to_string(aot)

  let assert Ok(kv) = molt.set(molt.new(), "x", value.int(1))
  let kv = molt.set_document_comments(kv, molt.Header, ["head"])
  let assert Ok(kv) = molt.set(kv, "y", value.int(2))
  assert "# head\n\nx = 1\ny = 2\n" == molt.to_string(kv)
  assert ["# head"] == molt.get_document_comments(kv, molt.Header)
  assert Ok(Comments(leading: [], trailing: None))
    == molt.get_comments(doc: kv, path: "x")
}

pub fn remove_head_comment_via_empty_set_test() {
  // Removal is set_document_comments with an empty list; it clears the slot.
  let doc = molt.set_document_comments(molt.new(), molt.Header, ["head"])
  let doc = molt.set_document_comments(doc, molt.Header, [])
  assert "" == molt.to_string(doc)
  assert [] == molt.get_document_comments(doc, molt.Header)
}

// --- Document-tail comments via the Tail slot ---

pub fn get_tail_comment_reads_dangling_block_test() {
  let assert Ok(doc) = molt.parse("x = 1\n# t1\n# t2\n")
  assert ["# t1", "# t2"] == molt.get_document_comments(doc, molt.Trailer)
  assert [] == molt.get_document_comments(doc, molt.Header)
}

pub fn set_tail_comment_materializes_postscript_test() {
  let assert Ok(doc) = molt.parse("x = 1\n")
  assert [] == molt.get_document_comments(doc, molt.Trailer)
  let doc = molt.set_document_comments(doc, molt.Trailer, ["bye"])
  // Setting the tail always separates it from the content with a blank line.
  assert "x = 1\n\n# bye\n" == molt.to_string(doc)
  assert ["# bye"] == molt.get_document_comments(doc, molt.Trailer)
}

pub fn parsed_tail_without_blank_round_trips_without_blank_test() {
  // A parsed tail keeps the source spacing: a comment directly after the last
  // statement (no blank) round-trips byte-exact — the set-only separator does
  // not retroactively apply to parsed tails.
  let assert Ok(doc) = molt.parse("x = 1\n# bye\n")
  assert "x = 1\n# bye\n" == molt.to_string(doc)
  assert ["# bye"] == molt.get_document_comments(doc, molt.Trailer)
}

pub fn set_tail_comment_empty_drops_postscript_test() {
  let assert Ok(doc) = molt.parse("x = 1\n# bye\n")
  let doc = molt.set_document_comments(doc, molt.Trailer, [])
  assert "x = 1\n" == molt.to_string(doc)
  assert [] == molt.get_document_comments(doc, molt.Trailer)
}

pub fn head_and_tail_are_independent_slots_test() {
  let assert Ok(doc) = molt.parse("# head\n\nx = 1\n# tail\n")
  assert ["# head"] == molt.get_document_comments(doc, molt.Header)
  assert ["# tail"] == molt.get_document_comments(doc, molt.Trailer)
  assert "# head\n\nx = 1\n# tail\n" == molt.to_string(doc)
}

pub fn set_head_comment_inserts_blank_separator_for_round_trip_test() {
  // Adding a head comment to a doc with content emits a blank line before the
  // first statement, so re-parsing recognizes it as a head comment again.
  let assert Ok(doc) = molt.parse("x = 1\n")
  let doc = molt.set_document_comments(doc, molt.Header, ["title"])
  assert "# title\n\nx = 1\n" == molt.to_string(doc)
  let assert Ok(reparsed) = molt.parse(molt.to_string(doc))
  assert ["# title"] == molt.get_document_comments(reparsed, molt.Header)
}

pub fn set_head_comment_separator_tracks_crlf_line_endings_test() {
  // The synthesized separator (and comment newline) matches the document's
  // existing line-ending style — CRLF in, CRLF out.
  let assert Ok(doc) = molt.parse("x = 1\r\n")
  let doc = molt.set_document_comments(doc, molt.Header, ["title"])
  assert "# title\r\n\r\nx = 1\r\n" == molt.to_string(doc)
}

pub fn set_tail_comment_tracks_crlf_line_endings_test() {
  let assert Ok(doc) = molt.parse("x = 1\r\n")
  let doc = molt.set_document_comments(doc, molt.Trailer, ["bye"])
  assert "x = 1\r\n\r\n# bye\r\n" == molt.to_string(doc)
}

pub fn edits_adopt_the_document_newline_style_test() {
  // Synthesized newlines (a new key, a node comment, a new table header) render
  // in the document's existing line-ending style rather than a hardcoded `\n`.
  let assert Ok(doc) = molt.parse("a = 1\r\n")
  let assert Ok(doc) = molt.set(doc, "b", value.int(2))
  assert "a = 1\r\nb = 2\r\n" == molt.to_string(doc)

  let assert Ok(doc) = molt.parse("a = 1\r\n")
  let assert Ok(doc) =
    molt.set_comments(doc:, path: "a", comments: Comments(["note"], None))
  assert "# note\r\na = 1\r\n" == molt.to_string(doc)

  let assert Ok(doc) = molt.parse("a = 1\r\n")
  let assert Ok(doc) = molt.ensure_exists(doc:, path: "srv", kind: types.Table)
  assert "a = 1\r\n\r\n[srv]\r\n" == molt.to_string(doc)
}

pub fn newline_detection_skips_synthetic_newlines_test() {
  // Adding a head comment to a doc with no head puts synthetic (empty-text)
  // newlines at the very top; detection must skip them and read the body's CRLF.
  let assert Ok(doc) = molt.parse("a = 1\r\n")
  let doc = molt.set_document_comments(doc, molt.Header, ["title"])
  assert "# title\r\n\r\na = 1\r\n" == molt.to_string(doc)
}

pub fn from_scratch_document_defaults_to_lf_test() {
  // A document with no parsed newline to learn from defaults to Unix newlines.
  let assert Ok(doc) = molt.set(molt.new(), "a", value.int(1))
  let doc = molt.set_document_comments(doc, molt.Header, ["title"])
  assert "# title\n\na = 1\n" == molt.to_string(doc)
}

pub fn mixed_line_endings_round_trip_byte_exact_test() {
  // Parsed newlines keep their literal text, so even a mixed-ending document
  // round-trips byte-for-byte (only synthesized newlines adopt the doc style).
  let src = "a = 1\nb = 2\r\nc = 3\n"
  let assert Ok(doc) = molt.parse(src)
  assert src == molt.to_string(doc)
}

pub fn bom_document_head_comment_is_addressable_test() {
  // A BOM precedes the head comment in the output, and the head comment is still
  // reachable through the Head slot (the BOM is document-head trivia, not a key).
  let assert Ok(doc) = molt.parse("\u{FEFF}# a\n\n# c\nx = 1\n")
  assert ["# a"] == molt.get_document_comments(doc, molt.Header)
  assert Ok(Comments(leading: ["# c"], trailing: None))
    == molt.get_comments(doc:, path: "x")
  assert "\u{FEFF}# a\n\n# c\nx = 1\n" == molt.to_string(doc)
}

pub fn bom_document_round_trips_with_set_head_comment_test() {
  // Setting a head comment on a BOM document keeps the BOM first.
  let assert Ok(doc) = molt.parse("\u{FEFF}x = 1\n")
  let doc = molt.set_document_comments(doc, molt.Header, ["title"])
  assert "\u{FEFF}# title\n\nx = 1\n" == molt.to_string(doc)
  assert ["# title"] == molt.get_document_comments(doc, molt.Header)
}

pub fn empty_path_rejected_by_path_comment_api_test() {
  // The path-based comment API no longer accepts the empty path; document-level
  // comments are reached only through the Head / Tail slots.
  let assert Ok(doc) = molt.parse("x = 1\n")
  let assert Error(InvalidOperation(operation: "get_comments", ..)) =
    molt.get_comments(doc:, path: "")
  let assert Error(InvalidOperation(operation: "set_comments", ..)) =
    molt.set_comments(doc:, path: "", comments: Comments([], None))
  let assert Error(InvalidOperation(operation: "move_comments", ..)) =
    molt.move_comments(doc:, from: "", to: "x")
  let assert Error(InvalidOperation(operation: "move_comments", ..)) =
    molt.move_comments(doc:, from: "x", to: "")
}

pub fn has_existing_key_test() {
  let assert Ok(doc) = molt.parse("[server]\nport = 8080\n")
  assert molt.has(doc:, path: "server.port")
}

pub fn has_missing_key_test() {
  let assert Ok(doc) = molt.parse("[server]\nport = 8080\n")
  assert !molt.has(doc:, path: "server.host")
}

pub fn has_table_test() {
  let assert Ok(doc) = molt.parse("[server]\nport = 8080\n")
  assert molt.has(doc:, path: "server")
}

pub fn has_root_test() {
  let assert Ok(doc) = molt.parse("x = 1\n")
  assert molt.has(doc:, path: "")
}

pub fn keys_of_table_test() {
  let assert Ok(doc) =
    molt.parse("[server]\nhost = \"localhost\"\nport = 8080\n")
  let assert Ok(keys) = molt.keys(doc:, path: "server")
  assert list.contains(keys, "host")
  assert list.contains(keys, "port")
  assert list.length(keys) == 2
}

pub fn keys_of_root_test() {
  let assert Ok(doc) = molt.parse("name = \"test\"\nversion = 1\n")
  let assert Ok(keys) = molt.keys(doc:, path: "")
  assert list.contains(keys, "name")
  assert list.contains(keys, "version")
  assert list.length(keys) == 2
}

pub fn get_scalar_test() {
  let assert Ok(doc) = molt.parse("[server]\nport = 8080\n")
  let assert Ok(_) = molt.get(doc:, path: "server.port")
}

pub fn get_missing_test() {
  let assert Ok(doc) = molt.parse("[server]\nport = 8080\n")
  let assert Error(NotFound(path: "server.nope", ..)) =
    molt.get(doc:, path: "server.nope")
}

pub fn get_inline_array_element_test() {
  let assert Ok(doc) = molt.parse("tags = [\"a\", \"b\", \"c\"]\n")
  let assert Ok(v) = molt.get(doc:, path: "tags[1]")
  let assert Ok("b") = value.unwrap_string(v)
}

pub fn get_inline_array_negative_index_test() {
  let assert Ok(doc) = molt.parse("tags = [\"a\", \"b\", \"c\"]\n")
  let assert Ok(v) = molt.get(doc:, path: "tags[-1]")
  let assert Ok("c") = value.unwrap_string(v)
}

pub fn has_inline_array_element_test() {
  let assert Ok(doc) = molt.parse("tags = [\"a\", \"b\"]\n")
  assert molt.has(doc:, path: "tags[0]")
  assert molt.has(doc:, path: "tags[1]")
  assert !molt.has(doc:, path: "tags[5]")
}

pub fn get_aot_entry_test() {
  let assert Ok(doc) =
    molt.parse("[[products]]\nname = \"A\"\n[[products]]\nname = \"B\"\n")
  let assert Ok(v) = molt.get(doc:, path: "products[1]")
  let assert Ok(name) = value.table_get_key(v, "name")
  let assert Ok("B") = value.unwrap_string(name)
}

pub fn get_aot_as_value_test() {
  let assert Ok(doc) =
    molt.parse("[[products]]\nname = \"A\"\n[[products]]\nname = \"B\"\n")
  let assert Ok(v) = molt.get(doc:, path: "products")
  assert "array_of_tables" == value.type_of(v)
  let assert Ok(items) = value.array_to_list(v)
  assert list.length(items) == 2
  let assert [first, second] = items
  let assert Ok(a) = value.table_get_key(first, "name")
  let assert Ok("A") = value.unwrap_string(a)
  let assert Ok(b) = value.table_get_key(second, "name")
  let assert Ok("B") = value.unwrap_string(b)
}

pub fn has_aot_entry_test() {
  let assert Ok(doc) =
    molt.parse("[[products]]\nname = \"A\"\n[[products]]\nname = \"B\"\n")
  assert molt.has(doc:, path: "products[0]")
  assert molt.has(doc:, path: "products[1]")
  assert !molt.has(doc:, path: "products[2]")
}

pub fn keys_of_aot_entry_test() {
  let assert Ok(doc) =
    molt.parse(
      "[[products]]\nname = \"A\"\nprice = 10\n[[products]]\nname = \"B\"\n",
    )
  let assert Ok(ks) = molt.keys(doc:, path: "products[0]")
  assert list.contains(ks, "name")
  assert list.contains(ks, "price")
}

pub fn get_dotted_root_key_test() {
  let assert Ok(doc) = molt.parse("a.b.c = 42\n")
  let assert Ok(v) = molt.get(doc:, path: "a.b.c")
  let assert Ok(42) = value.unwrap_int(v)
}

pub fn get_implicit_table_test() {
  let assert Ok(doc) = molt.parse("[a.b.c]\nd = 3\n")
  let assert Ok(v) = molt.get(doc:, path: "a.b")
  let assert Ok(entries) = value.table_to_list(v)
  assert list.any(entries, fn(e) { e.0 == "c" })
}

pub fn get_implicit_table_root_test() {
  let assert Ok(doc) = molt.parse("[a.b]\nx = 1\n")
  let assert Ok(v) = molt.get(doc:, path: "a")
  let assert Ok(entries) = value.table_to_list(v)
  assert list.any(entries, fn(e) { e.0 == "b" })
}

pub fn get_after_set_dotted_test() {
  let assert Ok(doc) = molt.parse("")
  let assert Ok(doc2) = molt.run(doc:, ops: [ops.Set("a.x", value.int(99))])
  let assert Ok(v) = molt.get(doc: doc2, path: "a.x")
  let assert Ok(99) = value.unwrap_int(v)
}

pub fn get_quoted_key_with_dots_test() {
  let assert Ok(doc) = molt.parse("'a.b.c' = \"hello\"\n")
  let assert Ok(v) = molt.get(doc:, path: "'a.b.c'")
  let assert Ok("hello") = value.unwrap_string(v)
}
