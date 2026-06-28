//// Tests for the Representation op: the four inline <-> block conversions,
//// both directions, with lossless round-trips. These also restore the
//// lossless-promotion coverage (inner comments, numeric forms) that the removed
//// inline-table promotion path previously covered.

import gleam/option.{Some}
import gleam/result
import gleam/string
import molt
import molt/error
import molt/ops
import molt/types

fn parse(src: String) -> types.Document {
  let assert Ok(doc) = molt.parse(src)
  doc
}

pub fn representation_block_inline_table_test() {
  let doc = parse("a = { x = 1, y = 2 }\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  let normalized = molt.normalize(doc2)
  assert molt.document_errors(normalized) == []
  assert molt.to_string(normalized) == "[a]\nx = 1\ny = 2\n"
}

pub fn representation_block_already_block_noop_test() {
  let doc = parse("[a]\nx = 1\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  assert molt.to_string(molt.normalize(doc2)) == "[a]\nx = 1\n"
}

pub fn representation_block_nested_inline_test() {
  let doc = parse("[p]\na = { x = 1 }\n")
  let assert Ok(doc2) = molt.representation(doc, "p.a", ops.Block)
  let normalized = molt.normalize(doc2)
  assert molt.document_errors(normalized) == []
  assert molt.to_string(normalized) == "[p]\n\n[p.a]\nx = 1\n"
}

// A TOML 1.1 inner comment survives the conversion (lossless).
pub fn representation_block_preserves_inner_comment_test() {
  let doc = parse("a = {\n  # note\n  x = 1,\n}\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  assert molt.to_string(doc2) == "[a]\n\n  # note\n  x = 1\n"
}

// A non-decimal integer form is preserved through the conversion.
pub fn representation_block_preserves_hex_int_test() {
  let doc = parse("a = { x = 0xff }\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  assert molt.to_string(doc2) == "[a]\nx = 0xff\n"
}

// A `[a]` section is converted to an inline table.
pub fn representation_inline_section_to_inline_test() {
  let doc = parse("[a]\nx = 1\ny = 2\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Inline)
  let normalized = molt.normalize(doc2)
  assert molt.document_errors(normalized) == []
  assert molt.to_string(normalized) == "a = { x = 1, y = 2 }\n"
}

// A trailing comment survives section -> inline (TOML 1.1 multiline inline).
pub fn representation_inline_preserves_trailing_comment_test() {
  let doc = parse("[a]\nx = 1 # note\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Inline)
  assert molt.to_string(doc2) == "a = {\nx = 1, # note\n}\n"
}

// After inline -> block, an entry's trailing comment lands on the section
// key-value's `trivia.trailing`, so it is addressable through the comment API
// (readable, movable, clearable) — not merely preserved in the emitted text.
pub fn representation_block_entry_trailing_comment_is_addressable_test() {
  let doc = parse("t = {\n  a = 1, # k\n  b = 2,\n}\n")
  let assert Ok(doc2) = molt.representation(doc, "t", ops.Block)
  let assert Ok(c) = molt.get_comments(doc2, "t.a")
  assert c == ops.Comments(leading: [], trailing: Some("# k"))
}

// An array of inline tables is converted to `[[a]]` entries.
pub fn representation_block_array_to_aot_test() {
  let doc = parse("a = [{ x = 1 }, { y = 2 }]\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  let normalized = molt.normalize(doc2)
  assert molt.document_errors(normalized) == []
  assert molt.to_string(normalized) == "[[a]]\nx = 1\n\n[[a]]\ny = 2\n"
}

// `[[a]]` entries are converted to an array of inline tables.
pub fn representation_inline_aot_to_array_test() {
  let doc = parse("[[a]]\nx = 1\n\n[[a]]\ny = 2\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Inline)
  let normalized = molt.normalize(doc2)
  assert molt.document_errors(normalized) == []
  assert molt.to_string(normalized) == "a = [{ x = 1 }, { y = 2 }]\n"
}

// An array whose elements are not all inline tables is not convertible.
pub fn representation_block_non_table_array_rejected_test() {
  let doc = parse("a = [1, 2, 3]\n")
  assert Error(error.TypeMismatch(
      path: Some("a"),
      expected: "array of inline tables",
      got: "value",
    ))
    == molt.representation(doc, "a", ops.Block)
}

// Table <-> inline-table round-trips back to the original.
pub fn representation_roundtrip_table_test() {
  let doc = parse("[a]\nx = 1\ny = 2\n")
  let assert Ok(out) =
    molt.representation(doc, "a", ops.Inline)
    |> result.try(molt.representation(_, "a", ops.Block))
  assert molt.to_string(molt.normalize(out)) == "[a]\nx = 1\ny = 2\n"
}

// A section that has descendant sub-tables has no lossless inline form and is
// refused (validate-after guard) rather than emitting invalid TOML.
pub fn representation_section_with_subtable_rejected_test() {
  let doc = parse("[a]\nx = 1\n\n[a.b]\ny = 2\n")
  let assert Error(error.InvalidOperation("representation", Some(_))) =
    molt.representation(doc, "a", ops.Inline)
}

// Empty table <-> empty inline table round-trips.
pub fn representation_empty_roundtrip_test() {
  let doc = parse("[a]\n")
  let assert Ok(inline) = molt.representation(doc, "a", ops.Inline)
  let assert True = molt.to_string(molt.normalize(inline)) == "a = {}\n"
  let assert Ok(back) = molt.representation(inline, "a", ops.Block)
  assert molt.to_string(molt.normalize(back)) == "[a]\n"
}

// A non-root array of tables family converts to an inline array inside its
// parent section.
pub fn representation_non_root_aot_to_inline_test() {
  let doc =
    parse(
      "[parent]\nq = 0\n\n[[parent.items]]\nx = 1\n\n[[parent.items]]\ny = 2\n",
    )
  let assert Ok(doc2) = molt.representation(doc, "parent.items", ops.Inline)
  let normalized = molt.normalize(doc2)
  assert molt.document_errors(normalized) == []
  assert molt.to_string(normalized)
    == "[parent]\nq = 0\nitems = [{ x = 1 }, { y = 2 }]\n"
}

// AoT <-> array-of-inline-tables round-trips back to the original.
pub fn representation_roundtrip_aot_test() {
  let doc = parse("a = [{ x = 1 }, { y = 2 }]\n")
  let assert Ok(out) =
    molt.representation(doc, "a", ops.Block)
    |> result.try(molt.representation(_, "a", ops.Inline))
  assert molt.to_string(molt.normalize(out)) == "a = [{ x = 1 }, { y = 2 }]\n"
}

// Inline -> block must not leak the inline table's `{ `, ` ,`, ` }` padding
// onto the section-form lines. Asserted on raw `to_string` (not `normalize`,
// which would rewrite the spacing and mask the bug).
pub fn representation_block_strips_inline_padding_test() {
  let doc = parse("a = { x = 1, y = 2 }\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  assert molt.to_string(doc2) == "[a]\nx = 1\ny = 2\n"
}

// A leading comment on the inline KV survives onto the new `[a]` header.
pub fn representation_block_preserves_leading_comment_test() {
  let doc = parse("# keep me\na = { x = 1 }\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  assert molt.to_string(doc2) == "# keep me\n[a]\nx = 1\n"
}

// A leading comment on the `[a]` header survives onto the new inline KV.
pub fn representation_inline_preserves_leading_comment_test() {
  let doc = parse("# keep me\n[a]\nx = 1\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Inline)
  assert molt.to_string(doc2) == "# keep me\na = { x = 1 }\n"
}

// Inline -> block on a nested inline table places the new `[deps.squall]`
// header adjacent to its parent scope (before the next section), not appended
// at the end of the document.
pub fn representation_block_nested_lands_by_parent_test() {
  let doc =
    parse("[deps]\na = 1\nsquall = { git = 'x' }\nb = 2\n\n[other]\nz = 3\n")
  let assert Ok(doc2) = molt.representation(doc, "deps.squall", ops.Block)
  let out = molt.to_string(doc2)
  let assert Ok(#(before_other, _)) = string.split_once(out, "[other]")
  let assert True = string.contains(before_other, "[deps.squall]")
  let assert Ok(reparsed) = molt.parse(out)
  assert !molt.has_errors(reparsed)
}

// Array-of-inline-tables -> AoT: the inline entries' KVs land in section form
// with no leaked `{ … }` padding.
pub fn representation_aot_block_strips_padding_test() {
  let doc = parse("a = [{ x = 1 }, { y = 2 }]\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  let out = molt.to_string(doc2)
  let assert True = string.contains(out, "x = 1\n")
  let assert False = string.contains(out, " x = 1")
  let assert False = string.contains(out, "x = 1 ")
}

// Array-of-inline-tables -> AoT: a comment on the whole `a = [ … ]` KV leads
// the first `[[a]]`.
pub fn representation_aot_block_preserves_whole_comment_test() {
  let doc = parse("# top\na = [{ x = 1 }, { y = 2 }]\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  let out = molt.to_string(doc2)
  assert out == "# top\n[[a]]\nx = 1\n\n[[a]]\ny = 2\n"
  let assert Ok(reparsed) = molt.parse(out)
  assert !molt.has_errors(reparsed)
}

// Array-of-inline-tables -> AoT: per-element comments in a multiline inline
// array lead their own `[[a]]` entries.
pub fn representation_aot_block_preserves_per_entry_comments_test() {
  let doc =
    parse("a = [\n  # first\n  { x = 1 },\n  # second\n  { y = 2 },\n]\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Block)
  let out = molt.to_string(doc2)
  assert out == "# first\n[[a]]\nx = 1\n\n# second\n[[a]]\ny = 2\n"
  let assert Ok(reparsed) = molt.parse(out)
  assert !molt.has_errors(reparsed)
}

// AoT -> array-of-inline-tables: a comment on a `[[a]]` is rendered as a
// multiline array so the comment keeps its own line.
pub fn representation_aot_inline_preserves_whole_comment_test() {
  let doc = parse("# top\n[[a]]\nx = 1\n\n[[a]]\ny = 2\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Inline)
  let out = molt.to_string(doc2)
  assert out == "a = [\n  # top\n  { x = 1 },\n  { y = 2 }\n]\n"
  let assert Ok(reparsed) = molt.parse(out)
  assert !molt.has_errors(reparsed)
}

// AoT -> array-of-inline-tables: a comment on each `[[a]]` survives the
// conversion (later entries become per-element comments) and stays valid TOML.
pub fn representation_aot_inline_preserves_per_entry_comments_test() {
  let doc = parse("# first\n[[a]]\nx = 1\n\n# second\n[[a]]\ny = 2\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Inline)
  let out = molt.to_string(doc2)
  assert out == "a = [\n  # first\n  { x = 1 },\n  # second\n  { y = 2 }\n]\n"
  let assert Ok(reparsed) = molt.parse(out)
  assert !molt.has_errors(reparsed)
}

// AoT -> array-of-inline-tables: a trailing comment on a `[[a]]` header
// survives onto its array element as `… # c` before the closing bracket,
// which stays valid TOML.
pub fn representation_aot_inline_preserves_trailing_comment_test() {
  let doc = parse("[[a]]\nx = 1\n\n[[a]] # last\ny = 2\n")
  let assert Ok(doc2) = molt.representation(doc, "a", ops.Inline)
  let out = molt.to_string(doc2)
  assert out == "a = [\n  { x = 1 },\n  { y = 2 } # last\n]\n"
  let assert Ok(reparsed) = molt.parse(out)
  assert !molt.has_errors(reparsed)
}

// Block -> inline collapses the inter-section blank line: converting a `[sub]`
// that had a preceding blank line into an inline KV must not carry the blank
// line onto the result.
pub fn representation_inline_collapses_leading_blank_line_test() {
  let doc =
    parse("[parent]\nhost = \"x\"\nport = 5432\n\n[parent.child]\na = 1\n")
  let assert Ok(doc2) = molt.representation(doc, "parent.child", ops.Inline)
  let out = molt.to_string(doc2)
  assert out == "[parent]\nhost = \"x\"\nport = 5432\nchild = { a = 1 }\n"
}

// Inline -> block adds a blank line before the new section header, so it gets
// conventional section spacing.
pub fn representation_block_adds_leading_blank_line_test() {
  let doc = parse("[parent]\nhost = \"x\"\nchild = { a = 1 }\n")
  let assert Ok(doc2) = molt.representation(doc, "parent.child", ops.Block)
  let out = molt.to_string(doc2)
  assert out == "[parent]\nhost = \"x\"\n\n[parent.child]\na = 1\n"
}
