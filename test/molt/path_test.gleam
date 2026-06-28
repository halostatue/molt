import molt/error
import molt/internal/path
import molt/types.{IndexSegment, KeySegment}

pub fn empty_path_test() {
  let assert Ok([]) = path.parse("")
}

pub fn simple_key_test() {
  let assert Ok([KeySegment("a")]) = path.parse("a")
}

pub fn dotted_path_test() {
  let assert Ok([KeySegment("a"), KeySegment("b"), KeySegment("c")]) =
    path.parse("a.b.c")
}

pub fn index_test() {
  let assert Ok([
    KeySegment("a"),
    KeySegment("b"),
    KeySegment("c"),
    IndexSegment(3),
  ]) = path.parse("a.b.c[3]")
}

pub fn negative_index_test() {
  let assert Ok([
    KeySegment("a"),
    KeySegment("b"),
    KeySegment("c"),
    IndexSegment(-1),
  ]) = path.parse("a.b.c[-1]")
}

pub fn chained_index_test() {
  let assert Ok([KeySegment("a"), IndexSegment(3), IndexSegment(4)]) =
    path.parse("a[3][4]")
}

pub fn index_then_key_test() {
  let assert Ok([KeySegment("a"), IndexSegment(3), KeySegment("d")]) =
    path.parse("a[3].d")
}

pub fn single_quoted_key_test() {
  let assert Ok([KeySegment("a.b"), KeySegment("c")]) = path.parse("'a.b'.c")
}

pub fn double_quoted_key_test() {
  let assert Ok([KeySegment("a.b"), KeySegment("c")]) = path.parse("\"a.b\".c")
}

pub fn quoted_brackets_suppressed_test() {
  let assert Ok([KeySegment("c[3]")]) = path.parse("\"c[3]\"")
}

pub fn single_quoted_brackets_suppressed_test() {
  let assert Ok([KeySegment("c[3]")]) = path.parse("'c[3]'")
}

pub fn double_quoted_escape_test() {
  let assert Ok([KeySegment("a\"b")]) = path.parse("\"a\\\"b\"")
}

pub fn error_unterminated_single_quote_test() {
  let assert Error(error.InvalidPath("unterminated single quote")) =
    path.parse("'abc")
}

pub fn error_unterminated_double_quote_test() {
  let assert Error(error.InvalidPath("unterminated double quote")) =
    path.parse("\"abc")
}

pub fn error_unterminated_bracket_test() {
  let assert Error(error.InvalidPath("unterminated bracket")) =
    path.parse("a[3")
}

pub fn error_non_integer_bracket_test() {
  let assert Error(error.InvalidPath("non-integer in brackets: xyz")) =
    path.parse("a[xyz]")
}

pub fn error_empty_segment_test() {
  let assert Error(error.InvalidPath("empty segment")) = path.parse("a..b")
}

pub fn error_trailing_dot_test() {
  let assert Error(error.InvalidPath("trailing dot")) = path.parse("a.b.")
}

pub fn error_leading_dot_test() {
  let assert Error(error.InvalidPath(_)) = path.parse(".a")
}

pub fn error_dot_bracket_test() {
  let assert Error(error.InvalidPath(_)) = path.parse("a.[-1]")
}

pub fn error_empty_brackets_test() {
  let assert Error(error.InvalidPath(_)) = path.parse("a[]")
}

pub fn error_float_in_brackets_test() {
  let assert Error(error.InvalidPath("non-integer in brackets: 1.2")) =
    path.parse("a[1.2]")
}

pub fn error_lone_minus_in_brackets_test() {
  let assert Error(error.InvalidPath(_)) = path.parse("a[-]")
}

pub fn error_missing_separator_after_index_test() {
  let assert Error(error.InvalidPath(_)) = path.parse("a[1]b")
}

pub fn error_index_first_test() {
  let assert Error(error.InvalidPath(_)) = path.parse("[0]")
}

pub fn key_with_spaces_test() {
  let assert Ok([KeySegment("with_space"), KeySegment("a b"), KeySegment("d")]) =
    path.parse("with_space.\"a b\".d")
}

pub fn error_bare_space_rejected_test() {
  // The counterpart to key_with_spaces_test: a space is not a bare-key
  // character, so the *unquoted* form is rejected rather than silently accepted.
  let assert Error(error.InvalidPath(
    "invalid character ' ' in bare key segment; quote the segment with ' or \"",
  )) = path.parse("a b")
}

pub fn error_bare_special_char_rejected_test() {
  // Likewise for other non-bare-key characters such as `$` (which would
  // otherwise be needed for any document-trivia anchor scheme).
  let assert Error(error.InvalidPath(
    "invalid character '$' in bare key segment; quote the segment with ' or \"",
  )) = path.parse("$x")
}

pub fn bare_dash_underscore_digit_key_test() {
  // Dashes, underscores, and digits ARE valid bare-key characters, so a key
  // like `-1` stays addressable without quoting.
  let assert Ok([KeySegment("a-b_c9"), KeySegment("-1")]) =
    path.parse("a-b_c9.-1")
}

pub fn chained_index_with_key_test() {
  let assert Ok([
    KeySegment("t"),
    IndexSegment(0),
    IndexSegment(1),
    KeySegment("k"),
  ]) = path.parse("t[0][1].k")
}

pub fn complex_array_path_test() {
  let assert Ok([
    KeySegment("arr"),
    IndexSegment(10),
    KeySegment("foo"),
    IndexSegment(0),
  ]) = path.parse("arr[10].foo[0]")
}

pub fn escaped_newline_in_key_test() {
  let assert Ok([KeySegment("a\nb"), KeySegment("k")]) =
    path.parse("\"a\\nb\".k")
}

pub fn resolve_path_parse_test() {
  let assert Ok([KeySegment("a"), KeySegment("b"), IndexSegment(0)]) =
    path.parse("a.b[0]")
}

pub fn path_to_string_parse_path_test() {
  let assert Ok(segments) = path.parse("a.b.c")
  assert "a.b.c" == path.to_string(segments)
}

pub fn path_to_string_direct_path_test() {
  let assert "a.b" = path.to_string([KeySegment("a"), KeySegment("b")])
}

pub fn leading_index_rejected_test() {
  let assert Error(error.InvalidPath("index segments must follow a key segment")) =
    path.parse("[0].a")
}

pub fn consecutive_index_allowed_test() {
  let assert Ok([KeySegment("a"), IndexSegment(0), IndexSegment(1)]) =
    path.parse("a[0][1]")
}

pub fn valid_index_after_key_test() {
  let assert Ok([KeySegment("a"), IndexSegment(2), KeySegment("b")]) =
    path.parse("a[2].b")
}
