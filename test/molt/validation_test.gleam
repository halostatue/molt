import molt
import molt/types

pub fn validator_rejects_key_as_table_test() {
  let assert Ok(doc) = molt.parse("a.b = 1\na.b.c = 2\n")
  let assert [types.SyntaxError(kind: types.KeyIsScalar(key: "b", ..), ..)] =
    molt.document_errors(doc)
}

pub fn validator_rejects_inline_table_as_table_test() {
  let assert Ok(doc) = molt.parse("a = { b = 1 }\na.c = 2\n")
  let assert [types.SyntaxError(kind: types.KeyIsInlineTable(key: "a", ..), ..)] =
    molt.document_errors(doc)
}

pub fn validator_rejects_inline_array_as_table_test() {
  let assert Ok(doc) = molt.parse("a = [1, 2]\na.b = 3\n")
  let assert [types.SyntaxError(kind: types.KeyIsArray(key: "a", ..), ..)] =
    molt.document_errors(doc)
}

pub fn validator_rejects_duplicate_key_test() {
  let assert Ok(doc) = molt.parse("a = 1\na = 2\n")
  let assert [types.SyntaxError(kind: types.DuplicateKey(key: "a", ..), ..)] =
    molt.document_errors(doc)
}

pub fn validator_rejects_duplicate_key_in_table_test() {
  let assert Ok(doc) = molt.parse("[t]\nx = 1\nx = 2\n")
  let assert [types.SyntaxError(kind: types.DuplicateKey(key: "x", ..), ..)] =
    molt.document_errors(doc)
}

pub fn validator_rejects_duplicate_key_in_inline_table_test() {
  let assert Ok(doc) = molt.parse("t = { b = 1, b = 2 }\n")
  let assert [
    types.SyntaxError(kind: types.DuplicateKeyInInlineTable(key: "b"), ..),
  ] = molt.document_errors(doc)
}

// --- Secondary spans ---
// Every semantic-conflict error carries TWO real source spans: the error's
// `span` points at the *conflict* (the second, offending definition) and the
// kind's `original` points at the *first* definition. To prove `original` is a
// real span and not a placeholder, each fixture puts the first definition on
// line 2 (after a leading comment): `original` must report line 2, never 1.

pub fn duplicate_table_carries_original_span_test() {
  // Two separate [foo] headers: the second fires DuplicateTable with an
  // `original` pointing to the first (on line 2).
  let assert Ok(doc) = molt.parse("# c\n[foo]\n\n[foo]\n")
  let assert [
    types.SyntaxError(kind: types.DuplicateTable(original:), span: conflict, ..),
  ] = molt.document_errors(doc)
  assert original == types.Span(line: 2, col: 1, offset: 4)
  assert conflict == types.Span(line: 4, col: 1, offset: 11)
}

pub fn key_is_scalar_carries_original_span_test() {
  // `a.b = 1` then `[a.b.c]`: the table header descends through the scalar.
  let assert Ok(doc) = molt.parse("# c\na.b = 1\n\n[a.b.c]\n")
  let assert [
    types.SyntaxError(
      kind: types.KeyIsScalar(key: "b", original:),
      span: conflict,
      ..,
    ),
  ] = molt.document_errors(doc)
  assert original == types.Span(line: 2, col: 1, offset: 4)
  assert conflict == types.Span(line: 4, col: 1, offset: 13)
}

pub fn duplicate_key_carries_original_span_test() {
  // Root-level duplicate `a`: the dotted/duplicate-key path (formerly a
  // `Span(1, 1, 0)` placeholder) now reports both real spans.
  let assert Ok(doc) = molt.parse("# c\na = 1\n\na = 2\n")
  let assert [
    types.SyntaxError(
      kind: types.DuplicateKey(key: "a", original:),
      span: conflict,
      ..,
    ),
  ] = molt.document_errors(doc)
  assert original == types.Span(line: 2, col: 1, offset: 4)
  assert conflict == types.Span(line: 4, col: 1, offset: 11)
}

pub fn key_is_inline_table_carries_original_span_test() {
  // `a = { b = 1 }` then dotted `a.c = 2` descends through the inline table.
  let assert Ok(doc) = molt.parse("# c\na = { b = 1 }\n\na.c = 2\n")
  let assert [
    types.SyntaxError(
      kind: types.KeyIsInlineTable(key: "a", original:),
      span: conflict,
      ..,
    ),
  ] = molt.document_errors(doc)
  assert original == types.Span(line: 2, col: 1, offset: 4)
  assert conflict == types.Span(line: 4, col: 1, offset: 19)
}

pub fn key_is_array_carries_original_span_test() {
  // `a = [1, 2]` then dotted `a.b = 3` descends through the inline array.
  let assert Ok(doc) = molt.parse("# c\na = [1, 2]\n\na.b = 3\n")
  let assert [
    types.SyntaxError(
      kind: types.KeyIsArray(key: "a", original:),
      span: conflict,
      ..,
    ),
  ] = molt.document_errors(doc)
  assert original == types.Span(line: 2, col: 1, offset: 4)
  assert conflict == types.Span(line: 4, col: 1, offset: 16)
}

// --- String-delimiter offset correctness (the `:256` fix) ---
// TOML string tokens store their content WITHOUT delimiters (and `...Nl`
// multiline variants without their leading newline). The position cursor must
// re-add them or anything after a string lands at the wrong column/offset. The
// bug this fixes only surfaces in enrich mode (count never tracks position), so
// these pin spans that are only correct once delimiters are counted.

pub fn span_after_string_on_same_line_test() {
  // `@` follows the 4-byte string `"hi"` on line 1: col 10, offset 9. The bug
  // counted `"hi"` as 2 bytes, which would have reported col 8 / offset 7.
  let assert Ok(doc) = molt.parse("a = \"hi\" @\n")
  let assert [
    types.SyntaxError(kind: types.MultipleValues, ..),
    types.SyntaxError(kind: types.BadValue("@"), span:, ..),
  ] = molt.document_errors(doc)
  assert span == types.Span(line: 1, col: 10, offset: 9)
}

pub fn span_after_string_across_lines_test() {
  // The duplicate `a` on line 3 begins at offset 18 only when line 1's 7-byte
  // string `"hello"` is counted in full (both delimiters included).
  let assert Ok(doc) = molt.parse("a = \"hello\"\nb = 1\na = 2\n")
  let assert [
    types.SyntaxError(kind: types.DuplicateKey(key: "a", ..), span:, ..),
  ] = molt.document_errors(doc)
  assert span == types.Span(line: 3, col: 1, offset: 18)
}

pub fn span_after_multiline_string_test() {
  // `@` follows the 9-byte multiline literal `'''abc'''` on line 1: col 15,
  // offset 14. Exercises the six delimiter bytes of a multiline string.
  let assert Ok(doc) = molt.parse("t = '''abc''' @\n")
  let assert [
    types.SyntaxError(kind: types.MultipleValues, ..),
    types.SyntaxError(kind: types.BadValue("@"), span:, ..),
  ] = molt.document_errors(doc)
  assert span == types.Span(line: 1, col: 15, offset: 14)
}
