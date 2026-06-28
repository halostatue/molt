//// molt: TOML document query paths.

import gleam/bool
import gleam/int
import gleam/list
import gleam/string
import molt/error.{type MoltError}
import molt/internal/utils
import molt/types.{type Path, type PathSegment, IndexSegment, KeySegment}

/// Eagerly parse a path string into a Path. Validates syntax.
///
/// Path syntax follows TOML key quoting rules extended with bracket indexing:
/// - `a.b.c`: key segments separated by dots
/// - `a[0]`: index into array
/// - `a[-1]`: negative index (from end)
/// - `'a.b'.c`: quoted literal key (suppresses dot/bracket parsing)
/// - `"a.b".c`: quoted basic key (allows escapes)
pub fn parse(input: String) -> Result(Path, MoltError) {
  case input {
    "" -> Ok([])
    _ ->
      case
        parse_path_segments(
          chars: string.to_graphemes(input),
          segments: [],
          current: "",
          needs: False,
        )
      {
        Ok(segments) -> validate_segments(segments)
        Error(error) -> Error(error)
      }
  }
}

pub fn to_string(segments: Path) -> String {
  utils.path_to_string(segments)
}

pub fn with_segment_key_name(
  segment segment: PathSegment,
  or return: a,
  do do: fn(String) -> a,
) -> a {
  case segment {
    KeySegment(name) -> do(name)
    IndexSegment(_) -> return
  }
}

pub fn split_last_segment(segments: Path) -> #(Path, PathSegment) {
  use <- bool.guard(segments == [], return: #([], KeySegment("")))

  case list.reverse(segments) {
    [last, ..rest] -> #(list.reverse(rest), last)
    [] -> #([], KeySegment(""))
  }
}

/// Split a path at its last index segment: the prefix up to and including that
/// index (the array of tables entry to descend into), and the index-free
/// remainder after it (the key/header within that entry). `Error(Nil)` when the
/// path has no index segment.
///
/// e.g. `srv[0].db` -> `Ok(#([srv, [0]], [db]))`; `a.b` -> `Error(Nil)`.
pub fn split_at_last_index(segments: Path) -> Result(#(Path, Path), Nil) {
  do_split_at_last_index(list.reverse(segments), [])
}

fn do_split_at_last_index(
  rev_remaining: Path,
  after: Path,
) -> Result(#(Path, Path), Nil) {
  case rev_remaining {
    [] -> Error(Nil)
    [IndexSegment(i), ..rest] ->
      Ok(#(list.reverse([IndexSegment(i), ..rest]), after))
    [segment, ..rest] -> do_split_at_last_index(rest, [segment, ..after])
  }
}

pub fn drop_last_segment(path: Path) -> Path {
  let #(path, _) = split_last_segment(path)
  path
}

/// Reduce a path to its key segments, dropping any index segments, to form the
/// dotted key list for a `[table]` / `[[array of tables]]` header. TOML headers
/// cannot carry an index, so the drop is intentional — but it is only safe
/// where the result builds or emits a header. Where an index segment is
/// meaning-bearing (path matching / re-scoping), guard with `contains_index`
/// instead of relying on the silent drop.
pub fn path_to_table_header(segments: Path) -> List(String) {
  list.filter_map(segments, fn(seg) {
    case seg {
      KeySegment(k) -> Ok(k)
      IndexSegment(_) -> Error(Nil)
    }
  })
}

/// True if any segment of the path is an index, e.g. the `[1]` in `a[1].b`.
///
/// Use this to guard operations that cannot honour an index segment (path
/// matching, header rewriting, implicit-table / array of tables family edits)
/// rather than silently dropping it via `path_to_table_header`.
pub fn contains_index(segments: Path) -> Bool {
  list.any(segments, is_index_segment)
}

fn is_index_segment(seg: PathSegment) -> Bool {
  case seg {
    IndexSegment(_) -> True
    KeySegment(_) -> False
  }
}

fn validate_segments(segments: Path) -> Result(Path, MoltError) {
  case segments {
    [IndexSegment(_), ..] ->
      Error(error.InvalidPath("index segments must follow a key segment"))
    _ -> Ok(segments)
  }
}

fn parse_path_segments(
  chars chars: List(String),
  segments segments: Path,
  current current: String,
  needs need_segment: Bool,
) -> Result(Path, error.MoltError) {
  case chars {
    [] ->
      case current, need_segment {
        "", True -> Error(error.InvalidPath("trailing dot"))
        "", False -> Ok(list.reverse(segments))
        _, _ -> Ok(list.reverse([KeySegment(current), ..segments]))
      }

    [".", ..rest] ->
      case current, need_segment || segments == [] {
        "", True -> Error(error.InvalidPath("empty segment"))
        "", False ->
          parse_path_segments(chars: rest, segments:, current: "", needs: True)
        _, _ ->
          parse_path_segments(
            chars: rest,
            segments: [KeySegment(current), ..segments],
            current: "",
            needs: True,
          )
      }

    ["[", ..rest] -> {
      // Reject dot immediately before bracket (a.[-1])
      use <- bool.guard(
        need_segment && current == "",
        return: Error(error.InvalidPath("empty segment before bracket")),
      )
      let segments = case current {
        "" -> segments
        _ -> [KeySegment(current), ..segments]
      }
      case parse_path_bracket_index(rest, "") {
        Ok(#(index, remaining)) ->
          parse_path_after_bracket(chars: remaining, segments: [
            IndexSegment(index),
            ..segments
          ])
        Error(error) -> Error(error)
      }
    }

    ["'", ..chars] -> {
      use <- bool.guard(
        current != "",
        return: Error(error.InvalidPath("unexpected quote in bare key")),
      )
      parse_path_single_quoted(chars:, segments:, acc: "")
    }

    ["\"", ..chars] -> {
      use <- bool.guard(
        current != "",
        return: Error(error.InvalidPath("unexpected quote in bare key")),
      )
      parse_path_double_quoted(chars:, segments:, acc: "")
    }

    [ch, ..chars] -> {
      // Bare segments are restricted to TOML bare-key characters
      // (`A-Za-z0-9_-`). Any other character (a space, `$`, `^`, …) must be
      // quoted: `'a b'` or `"a b"`. Reject it here rather than silently
      // accepting a segment that bare-key syntax can't represent.
      use <- bool.guard(
        !utils.is_bare_key(ch),
        return: Error(error.InvalidPath(
          "invalid character '"
          <> ch
          <> "' in bare key segment; quote the segment with ' or \"",
        )),
      )

      parse_path_segments(
        chars:,
        segments:,
        current: current <> ch,
        needs: False,
      )
    }
  }
}

/// After a bracket close, only allow `.`, `[`, or end-of-input.
fn parse_path_after_bracket(
  chars chars: List(String),
  segments segments: Path,
) -> Result(Path, error.MoltError) {
  case chars {
    [] -> Ok(list.reverse(segments))
    [".", ..rest] ->
      parse_path_segments(chars: rest, segments:, current: "", needs: True)
    ["[", ..rest] ->
      case parse_path_bracket_index(rest, "") {
        Ok(#(index, remaining)) ->
          parse_path_after_bracket(chars: remaining, segments: [
            IndexSegment(index),
            ..segments
          ])
        Error(error) -> Error(error)
      }
    _ -> Error(error.InvalidPath("expected dot or bracket after index"))
  }
}

fn parse_path_bracket_index(
  chars: List(String),
  acc: String,
) -> Result(#(Int, List(String)), error.MoltError) {
  case chars {
    [] -> Error(error.InvalidPath("unterminated bracket"))
    ["]", ..rest] ->
      case int.parse(acc) {
        Ok(n) -> Ok(#(n, rest))
        Error(_) -> Error(error.InvalidPath("non-integer in brackets: " <> acc))
      }
    [ch, ..rest] -> parse_path_bracket_index(rest, acc <> ch)
  }
}

fn parse_path_single_quoted(
  chars chars: List(String),
  segments segments: Path,
  acc acc: String,
) -> Result(Path, error.MoltError) {
  case chars {
    [] -> Error(error.InvalidPath("unterminated single quote"))
    ["'", ..chars] ->
      parse_path_segments(
        chars:,
        segments: [KeySegment(acc), ..segments],
        current: "",
        needs: False,
      )
    [ch, ..chars] -> parse_path_single_quoted(chars:, segments:, acc: acc <> ch)
  }
}

fn parse_path_double_quoted(
  chars chars: List(String),
  segments segments: Path,
  acc acc: String,
) -> Result(Path, error.MoltError) {
  case chars {
    [] -> Error(error.InvalidPath("unterminated double quote"))
    ["\\", ..chars] ->
      case chars {
        [] -> Error(error.InvalidPath("unterminated double quote"))
        [escaped, ..chars] -> {
          let ch = case escaped {
            "n" -> "\n"
            "t" -> "\t"
            "r" -> "\r"
            "\\" -> "\\"
            "\"" -> "\""
            _ -> "\\" <> escaped
          }
          parse_path_double_quoted(chars:, segments:, acc: acc <> ch)
        }
      }
    ["\"", ..chars] ->
      parse_path_segments(
        chars:,
        segments: [KeySegment(acc), ..segments],
        current: "",
        needs: False,
      )
    [ch, ..chars] -> parse_path_double_quoted(chars:, segments:, acc: acc <> ch)
  }
}
