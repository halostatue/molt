//// TOML semantic validation over the CST produced by the parser.
////
//// Single-pass validation: walks the tree depth-first, tracking byte offset,
//// line, and column. Collects all validation errors with rich position info:
//// duplicate keys/tables, structural syntax errors, invalid values, and
//// unparsable content.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import greenwood.{
  type Element, type Node, type Token, Continue, NodeElement as N, Token,
  TokenElement as T,
}
import molt/internal/cst/elements
import molt/internal/utils
import molt/types.{type Span, type SyntaxError, type TomlKind, Span}

/// What kind of definition a path represents. Every variant carries the span at
/// which the path was first registered so that error-construction sites can
/// populate `original` on conflict kinds.
type PathEntry {
  /// Explicitly defined by a [table] header
  ExplicitTable(span: Span)
  /// Explicitly defined by a [[array-table]] header
  ExplicitArrayOfTables(instance: Int, span: Span)
  /// Implicitly created as a parent of a header path.
  HeaderImplicit(span: Span)
  /// Implicitly created by a dotted key in the currently-open table block.
  DottedImplicit(span: Span)
  /// Frozen DottedImplicit (the block that created it has closed).
  ClosedImplicit(span: Span)
  /// Explicitly assigned to a scalar value by a key-value pair.
  ExplicitScalar(span: Span)
  /// Explicitly assigned to an inline table by a key-value pair.
  ExplicitInlineTable(span: Span)
  /// Explicitly assigned to an inline array by a key-value pair.
  ExplicitInlineArray(span: Span)
}

/// Shape of the value a key-value pair binds to. Used to pick the right
/// `ExplicitX` `PathEntry` so descent-through-value checks can emit
/// `KeyIsScalar` / `KeyIsInlineTable` / `KeyIsArray` rather than a generic
/// duplicate-key error.
type ValueKind {
  ScalarValue
  InlineTableValue
  InlineArrayValue
}

/// Position cursor tracking source location.
type Pos {
  Pos(line: Int, col: Int, offset: Int)
}

/// A strategy for accumulating rule violations during the walk. The rule logic
/// is shared across modes; only the collector differs, which is what keeps the
/// two modes from drifting on *which* documents are invalid:
///
/// - **count** threads an `Int`, increments on each violation, and never invokes
///   the builder thunk — so it constructs no `SyntaxError` and reads no span.
///   `track_pos` is `False`, so `advance_text`'s offset/line/col arithmetic is
///   skipped entirely.
/// - **enrich** threads a `List(SyntaxError)`, invokes the builder to produce a
///   fully-positioned error, and sets `track_pos` to `True` so the position
///   cursor advances.
type Collector(acc) {
  Collector(
    empty: acc,
    track_pos: Bool,
    on_violation: fn(acc, fn() -> SyntaxError) -> acc,
  )
}

/// Accumulated state during the validation walk. Generic over the collector's
/// accumulator `acc` (an `Int` in count mode, a `List(SyntaxError)` in enrich).
/// Rule-state (`path`, `path_stack`, `paths`, `array_counts`, `value_depth`) is
/// threaded identically in both modes; `pos` is only advanced when the active
/// collector's `track_pos` is set (enrich), so count does no position
/// arithmetic.
type State(acc) {
  State(
    collector: Collector(acc),
    acc: acc,
    pos: Pos,
    path: List(String),
    path_stack: List(List(String)),
    paths: Dict(List(String), PathEntry),
    array_counts: Dict(List(String), Int),
    // Depth of enclosing value-context nodes (Array / InlineTable). Top-level
    // key-value pairs sit at depth 0; nested inline-table KVs are deeper and
    // must NOT be registered into the top-level path map.
    value_depth: Int,
  )
}

/// Count the validation errors in a tree without building any.
///
/// Runs the shared rule walk with the count collector: no `SyntaxError` is
/// constructed and no offset/line/col arithmetic is performed (the position
/// cursor is never advanced). This is the mode `molt.parse` and document
/// construction use, so the common (valid) path pays only for rule bookkeeping.
pub fn count(tree: Node(TomlKind)) -> Int {
  walk(
    tree,
    Collector(empty: 0, track_pos: False, on_violation: fn(n, _build) { n + 1 }),
  )
}

/// Collect every validation error in a tree as a fully-positioned `SyntaxError`.
///
/// Runs the shared rule walk with the enrich collector, which threads the
/// position cursor (so spans are accurate) and invokes each violation's builder.
/// This is the on-demand mode behind `molt.document_errors`; the string-aware
/// offset reconstruction in `advance_text` is paid only here.
pub fn enrich(tree: Node(TomlKind)) -> List(SyntaxError) {
  walk(tree, enrich_collector())
  |> list.reverse
}

/// The enrich collector: accumulate fully-built `SyntaxError`s newest-first.
/// Shared by `enrich` and the inline-table duplicate-key probe so both build
/// errors the same way.
fn enrich_collector() -> Collector(List(SyntaxError)) {
  Collector(empty: [], track_pos: True, on_violation: fn(errors, build) {
    [build(), ..errors]
  })
}

/// Shared validation walk, parameterized over a `Collector`. Both `count` and
/// `enrich` run this exact traversal and rule logic; only the collector differs,
/// guaranteeing the two modes agree on which documents are invalid.
fn walk(tree: Node(TomlKind), collector: Collector(acc)) -> acc {
  case elements.is_toml(tree.children) {
    False ->
      collector.on_violation(collector.empty, fn() {
        types.SyntaxError(
          kind: types.NoValidTomlStructure,
          path: [],
          span: Span(line: 1, col: 1, offset: 0),
        )
      })
    True -> {
      let state =
        State(
          collector:,
          acc: collector.empty,
          pos: Pos(line: 1, col: 1, offset: 0),
          path: [],
          path_stack: [],
          paths: dict.new(),
          array_counts: dict.new(),
          value_depth: 0,
        )

      // Re-inline trailing comments so line/column tracking sees the source
      // layout (`value # comment\n`) rather than greenwood's
      // children-then-trailing-trivia order, which would count a line's trailing
      // comment on the next line.
      let tree = elements.inline_trailing_trivia(tree)

      let state =
        greenwood.visitor()
        |> greenwood.on_trivia(fn(state, tok) {
          Continue(advance_token(state, tok))
        })
        |> greenwood.on_token(fn(state, tok) {
          Continue(advance_token(state, tok))
        })
        |> greenwood.on_enter_node(fn(state, node) {
          Continue(enter_node(state, node))
        })
        |> greenwood.on_exit_node(fn(state, node) {
          Continue(exit_node(state, node))
        })
        |> greenwood.traverse(over: tree, from: state)

      state.acc
    }
  }
}

/// Hand a violation to the active collector. The `build` thunk produces the
/// fully-positioned `SyntaxError`; count mode discards it (so it never runs and
/// no span is computed), enrich mode invokes it.
fn emit(state: State(acc), build: fn() -> SyntaxError) -> State(acc) {
  State(..state, acc: state.collector.on_violation(state.acc, build))
}

fn enter_node(state: State(acc), node: Node(TomlKind)) -> State(acc) {
  case node.kind {
    types.Root ->
      // Root-level KVs register lazily at their own `KeyValue` enter, where the
      // position cursor has advanced to the key's real source span.
      state

    types.Error -> {
      // Treat an unparsable subtree as a value context: any KeyValue nodes the
      // parser salvaged inside it are not structural document keys and must not
      // be registered (check_kv_syntax still reports their syntax errors).
      let state =
        emit(state, fn() {
          make_error(state:, kind: types.UnparsableContent, path: state.path)
        })
      State(..state, value_depth: state.value_depth + 1)
    }

    types.Table -> {
      let table_path = elements.extract_key_segments(node.children)
      let state = freeze_dotted(state)
      let scoped = scope_header_path(state, table_path)
      let state = push_path(state, scoped)

      register_table(state, scoped)
      |> check_table_header_syntax(node:, path: table_path)
    }

    types.ArrayOfTables -> {
      let table_path = elements.extract_key_segments(node.children)
      let state =
        freeze_dotted(state)
        |> register_array_of_tables(table_path)
      let instance =
        { dict.get(state.array_counts, table_path) |> result.unwrap(1) } - 1
      let last = last_or_empty(table_path)
      let scoped_parent = scope_path(state, list_init(table_path))
      let scoped_path =
        list.append(scoped_parent, [last, int.to_string(instance)])

      push_path(state, scoped_path)
      |> check_table_header_syntax(node:, path: table_path)
    }

    types.KeyValue -> {
      // Register top-level KVs here (not at the enclosing table/root enter) so
      // the captured span reflects the key's real position. Nested inline-table
      // KVs (value_depth > 0) are part of a value, not the document structure.
      let state = case state.value_depth {
        0 -> register_kv(state:, table_path: state.path, kv: node)
        _ -> state
      }
      let kv_path =
        list.append(
          state.path,
          elements.key_path(node.children) |> option.unwrap([]),
        )

      push_path(state, kv_path)
      |> check_kv_syntax(node:, path: kv_path)
    }

    types.Array -> {
      let state = State(..state, value_depth: state.value_depth + 1)
      let state = push_path(state, state.path)
      check_array_syntax(state:, node:, path: state.path)
    }

    types.InlineTable -> {
      let state = State(..state, value_depth: state.value_depth + 1)
      let state = push_path(state, state.path)
      check_inline_table_syntax(state:, node:, path: state.path)
    }

    _ -> push_path(state, state.path)
  }
}

fn exit_node(state: State(acc), node: Node(TomlKind)) -> State(acc) {
  use <- bool.guard(node.kind == types.Root, return: state)
  // Error nodes increment value_depth on enter but never push a path, so undo
  // the depth bump without popping.
  use <- bool.guard(
    node.kind == types.Error,
    return: State(..state, value_depth: state.value_depth - 1),
  )
  let state = case node.kind {
    types.Array | types.InlineTable ->
      State(..state, value_depth: state.value_depth - 1)
    _ -> state
  }
  pop_path(state)
}

fn push_path(state: State(acc), new_path: List(String)) -> State(acc) {
  State(..state, path: new_path, path_stack: [state.path, ..state.path_stack])
}

fn pop_path(state: State(acc)) -> State(acc) {
  case state.path_stack {
    [parent, ..rest] -> State(..state, path: parent, path_stack: rest)
    [] -> state
  }
}

fn advance_token(state: State(acc), token: Token(TomlKind)) -> State(acc) {
  let state = case token.kind {
    types.InvalidValue ->
      emit(state, fn() {
        make_error(state:, kind: types.BadValue(text: token.text), path: [])
      })
    types.InvalidBasicString | types.InvalidLiteralString ->
      emit(state, fn() {
        make_error(state:, kind: types.UnterminatedString, path: [])
      })
    types.InvalidMultilineBasicString | types.InvalidMultilineLiteralString ->
      emit(state, fn() {
        make_error(state:, kind: types.UnterminatedMultilineString, path: [])
      })
    _ -> state
  }

  // The position cursor is threaded only in enrich mode; count skips all
  // offset/line/col arithmetic.
  case state.collector.track_pos {
    True -> advance_text(state:, text: token.text, kind: token.kind)
    False -> state
  }
}

fn advance_text(
  state state: State(acc),
  text text: String,
  kind kind: TomlKind,
) -> State(acc) {
  let Pos(line:, col:, offset:) = state.pos

  // Reconstruct each token's exact source text so offset/line/col advance by the
  // right amount. Fixed-text tokens store the empty string. TOML strings store
  // their content WITHOUT the surrounding delimiters (and, for the `...Nl`
  // multiline variants, without the leading newline that the kind encodes), so
  // wrap them back to source form — mirroring the emitter. Without this, a token
  // after a string on the same line lands at the wrong column and everything on
  // later lines is offset short by the delimiter bytes.
  let text = case kind {
    types.Equals -> "="
    types.Dot -> "."
    types.Comma -> ","
    types.LeftBracket -> "["
    types.RightBracket -> "]"
    types.LeftBrace -> "{"
    types.RightBrace -> "}"
    types.BasicString -> "\"" <> text <> "\""
    types.LiteralString -> "'" <> text <> "'"
    types.MultilineBasicString -> "\"\"\"" <> text <> "\"\"\""
    types.MultilineBasicStringNl -> "\"\"\"\n" <> text <> "\"\"\""
    types.MultilineLiteralString -> "'''" <> text <> "'''"
    types.MultilineLiteralStringNl -> "'''\n" <> text <> "'''"
    _ -> text
  }

  let len = string.byte_size(text)
  let #(new_line, new_col) = count_newlines(text:, line:, col:)

  State(..state, pos: Pos(line: new_line, col: new_col, offset: offset + len))
}

fn count_newlines(
  text text: String,
  line line: Int,
  col col: Int,
) -> #(Int, Int) {
  case text {
    "" -> #(line, col)
    "\r\n" <> rest | "\n" <> rest ->
      count_newlines(text: rest, line: line + 1, col: 1)
    _ -> {
      // Find next newline or end
      case string.pop_grapheme(text) {
        Ok(#(_, rest)) -> count_newlines(text: rest, line:, col: col + 1)
        Error(Nil) -> #(line, col)
      }
    }
  }
}

fn make_error(
  state state: State(acc),
  kind kind: types.SyntaxErrorKind,
  path path: List(String),
) -> SyntaxError {
  types.SyntaxError(kind:, path:, span: pos_span(state.pos))
}

fn pos_span(pos: Pos) -> Span {
  Span(line: pos.line, col: pos.col, offset: pos.offset)
}

fn entry_span(entry: PathEntry) -> Span {
  case entry {
    ExplicitTable(span:) -> span
    ExplicitArrayOfTables(span:, ..) -> span
    HeaderImplicit(span:) -> span
    DottedImplicit(span:) -> span
    ClosedImplicit(span:) -> span
    ExplicitScalar(span:) -> span
    ExplicitInlineTable(span:) -> span
    ExplicitInlineArray(span:) -> span
  }
}

fn freeze_dotted(state: State(acc)) -> State(acc) {
  State(
    ..state,
    paths: dict.map_values(state.paths, fn(_, v) {
      case v {
        DottedImplicit(span:) -> ClosedImplicit(span:)
        _ -> v
      }
    }),
  )
}

fn scope_path(state: State(acc), path: List(String)) -> List(String) {
  do_scope_path(
    state:,
    remaining: path,
    raw_current: [],
    scoped_current: [],
    scope_terminal: True,
  )
}

fn scope_header_path(state: State(acc), path: List(String)) -> List(String) {
  do_scope_path(
    state:,
    remaining: path,
    raw_current: [],
    scoped_current: [],
    scope_terminal: False,
  )
}

fn do_scope_path(
  state state: State(acc),
  remaining remaining: List(String),
  raw_current raw_current: List(String),
  scoped_current scoped_current: List(String),
  scope_terminal scope_terminal: Bool,
) -> List(String) {
  case remaining {
    [] -> scoped_current
    [segment, ..rest] -> {
      let raw_prefix = list.append(raw_current, [segment])
      let scoped_prefix = list.append(scoped_current, [segment])
      let scope_here = scope_terminal || rest != []
      case scope_here, dict.get(state.array_counts, raw_prefix) {
        True, Ok(instance) -> {
          do_scope_path(
            state:,
            remaining: rest,
            raw_current: raw_prefix,
            scoped_current: list.append(scoped_prefix, [int.to_string(instance)]),
            scope_terminal:,
          )
        }
        _, _ ->
          do_scope_path(
            state:,
            remaining: rest,
            raw_current: raw_prefix,
            scoped_current: scoped_prefix,
            scope_terminal:,
          )
      }
    }
  }
}

fn register_table(state: State(acc), path: List(String)) -> State(acc) {
  let span = pos_span(state.pos)
  let state = register_header_implicit_parents(state, path)
  case dict.get(state.paths, path) {
    Error(Nil) | Ok(HeaderImplicit(_)) ->
      State(
        ..state,
        paths: dict.insert(state.paths, path, ExplicitTable(span:)),
      )
    Ok(entry) -> {
      let original = entry_span(entry)
      let state =
        State(
          ..state,
          paths: dict.insert(state.paths, path, ExplicitTable(span:)),
        )
      emit(state, fn() {
        make_error(state:, kind: types.DuplicateTable(original:), path:)
      })
    }
  }
}

fn register_array_of_tables(
  state: State(acc),
  raw_path: List(String),
) -> State(acc) {
  let span = pos_span(state.pos)
  let scoped = scope_header_path(state, raw_path)
  let state = register_header_implicit_parents(state, scoped)
  let count =
    { dict.get(state.array_counts, raw_path) |> result.unwrap(-1) } + 1
  let state =
    State(
      ..state,
      array_counts: dict.insert(state.array_counts, raw_path, count),
    )
  case dict.get(state.paths, scoped) {
    Error(Nil) | Ok(ExplicitArrayOfTables(..)) ->
      State(
        ..state,
        paths: dict.insert(
          state.paths,
          scoped,
          ExplicitArrayOfTables(instance: count, span:),
        ),
      )
    Ok(entry) -> {
      let original = entry_span(entry)
      let state =
        State(
          ..state,
          paths: dict.insert(
            state.paths,
            scoped,
            ExplicitArrayOfTables(instance: count, span:),
          ),
        )
      emit(state, fn() {
        make_error(state:, kind: types.DuplicateTable(original:), path: scoped)
      })
    }
  }
}

fn register_kv(
  state state: State(acc),
  table_path table_path: List(String),
  kv kv: Node(TomlKind),
) -> State(acc) {
  case elements.key_path(kv.children) {
    None ->
      emit(state, fn() {
        make_error(state:, kind: types.InvalidKeySyntax, path: table_path)
      })
    Some(segments) ->
      register_kv_path(
        state:,
        table_path:,
        segments:,
        value_kind: kv_value_kind(kv),
      )
  }
}

fn register_kv_path(
  state state: State(acc),
  table_path table_path: List(String),
  segments segments: List(String),
  value_kind value_kind: ValueKind,
) -> State(acc) {
  let full_path = list.append(table_path, segments)
  let table_len = list.length(table_path)
  let dotted_prefixes =
    list.drop(utils.all_prefixes(path: full_path), table_len)
  let state = register_dotted_implicit_parents(state, dotted_prefixes)
  let key = last_or_empty(segments)
  let entry = value_kind_entry(value_kind, state.pos)
  case dict.get(state.paths, full_path) {
    Error(Nil) ->
      State(..state, paths: dict.insert(state.paths, full_path, entry))
    Ok(existing) -> {
      let original = entry_span(existing)
      let state =
        State(..state, paths: dict.insert(state.paths, full_path, entry))
      emit(state, fn() {
        make_error(
          state:,
          kind: types.DuplicateKey(key:, original:),
          path: table_path,
        )
      })
    }
  }
}

fn register_header_implicit_parents(
  state: State(acc),
  path: List(String),
) -> State(acc) {
  let parent_paths = utils.all_prefixes(path:)
  let span = pos_span(state.pos)
  list.fold(parent_paths, state, fn(state, prefix) {
    case dict.get(state.paths, prefix) {
      Error(Nil) ->
        State(
          ..state,
          paths: dict.insert(state.paths, prefix, HeaderImplicit(span:)),
        )
      Ok(ExplicitScalar(span: original)) ->
        emit_descent_error(state, prefix, fn(key) {
          types.KeyIsScalar(key:, original:)
        })
      Ok(ExplicitInlineTable(span: original)) ->
        emit_descent_error(state, prefix, fn(key) {
          types.KeyIsInlineTable(key:, original:)
        })
      Ok(ExplicitInlineArray(span: original)) ->
        emit_descent_error(state, prefix, fn(key) {
          types.KeyIsArray(key:, original:)
        })
      Ok(_) -> state
    }
  })
}

fn register_dotted_implicit_parents(
  state: State(acc),
  parent_paths: List(List(String)),
) -> State(acc) {
  let span = pos_span(state.pos)
  list.fold(parent_paths, state, fn(state, prefix) {
    case dict.get(state.paths, prefix) {
      Error(Nil) ->
        State(
          ..state,
          paths: dict.insert(state.paths, prefix, DottedImplicit(span:)),
        )
      Ok(DottedImplicit(_)) -> state
      Ok(ExplicitScalar(span: original)) ->
        emit_descent_error(state, prefix, fn(key) {
          types.KeyIsScalar(key:, original:)
        })
      Ok(ExplicitInlineTable(span: original)) ->
        emit_descent_error(state, prefix, fn(key) {
          types.KeyIsInlineTable(key:, original:)
        })
      Ok(ExplicitInlineArray(span: original)) ->
        emit_descent_error(state, prefix, fn(key) {
          types.KeyIsArray(key:, original:)
        })
      Ok(entry) -> {
        let original = entry_span(entry)
        emit(state, fn() {
          make_error(
            state:,
            kind: types.DuplicateTable(original:),
            path: prefix,
          )
        })
      }
    }
  })
}

/// Inspect a key-value pair's value to decide which `ExplicitX` entry to
/// register. This is what lets the descent-through-value gap checks distinguish
/// scalar/inline-table/inline-array ancestors.
fn kv_value_kind(kv: Node(TomlKind)) -> ValueKind {
  let value_tokens = elements.value_tokens(kv.children)
  case elements.find_first_value(value_tokens) {
    Some(N(n)) ->
      case n.kind {
        types.InlineTable -> InlineTableValue
        types.Array -> InlineArrayValue
        _ -> ScalarValue
      }
    _ -> ScalarValue
  }
}

fn value_kind_entry(value_kind: ValueKind, pos: Pos) -> PathEntry {
  let span = pos_span(pos)
  case value_kind {
    ScalarValue -> ExplicitScalar(span:)
    InlineTableValue -> ExplicitInlineTable(span:)
    InlineArrayValue -> ExplicitInlineArray(span:)
  }
}

/// Emit a descent-through-value error at `prefix` using the provided kind
/// constructor. The kind's `key` argument is the last segment of the prefix
/// (the offending key); the error's `path` is the parent prefix.
fn emit_descent_error(
  state: State(acc),
  prefix: List(String),
  kind_with_key: fn(String) -> types.SyntaxErrorKind,
) -> State(acc) {
  let key = last_or_empty(prefix)
  let parent = list_init(prefix)
  emit(state, fn() {
    make_error(state:, kind: kind_with_key(key), path: parent)
  })
}

fn check_kv_syntax(
  state state: State(acc),
  node node: Node(TomlKind),
  path path: List(String),
) -> State(acc) {
  let state = case check_key_tokens_ok(node) {
    True -> state
    False -> push_error(state:, kind: types.InvalidKeySyntax, path:)
  }
  let value_tokens = elements.value_tokens(node.children)
  let state = case has_value(value_tokens) {
    True -> state
    False -> push_error(state:, kind: types.MissingValue, path:)
  }
  // Invalid value tokens are reported per-token as `BadValue` from
  // `advance_token`; no need for a second kv-level error here.
  let state = case has_extra_equals(value_tokens) {
    False -> state
    True -> push_error(state:, kind: types.ExtraEquals, path:)
  }
  case has_single_value(value_tokens) {
    True -> state
    False -> push_error(state:, kind: types.MultipleValues, path:)
  }
}

fn push_error(
  state state: State(acc),
  kind kind: types.SyntaxErrorKind,
  path path: List(String),
) -> State(acc) {
  emit(state, fn() { make_error(state:, kind:, path:) })
}

fn check_table_header_syntax(
  state state: State(acc),
  node node: Node(TomlKind),
  path path: List(String),
) -> State(acc) {
  use <- bool.lazy_guard(path == [], return: fn() {
    push_error(state:, kind: types.EmptyTableHeader, path:)
  })

  let expected = case node.kind {
    types.ArrayOfTables -> 2
    _ -> 1
  }

  use <- bool.guard(
    check_table_bracket_shape_ok(node.children, expected),
    return: state,
  )
  push_error(state:, kind: types.MalformedTableHeader, path:)
}

fn check_array_syntax(
  state state: State(acc),
  node node: Node(TomlKind),
  path path: List(String),
) -> State(acc) {
  let state = case array_is_closed(node.children) {
    True -> state
    False -> push_error(state:, kind: types.UnterminatedArray, path:)
  }

  use <- bool.guard(array_separators_ok(node.children), return: state)

  // Invalid value tokens inside arrays are reported per-token as `BadValue`
  // from `advance_token`; no need for a second array-level error here.
  push_error(state:, kind: types.MisplacedArraySeparator, path:)
}

fn check_inline_table_syntax(
  state state: State(acc),
  node node: Node(TomlKind),
  path path: List(String),
) -> State(acc) {
  let state = case inline_table_is_closed(node.children) {
    True -> state
    False -> push_error(state:, kind: types.UnterminatedInlineTable, path:)
  }
  let state = case inline_table_first_duplicate_key(node.children) {
    None -> state
    Some(key) ->
      push_error(state:, kind: types.DuplicateKeyInInlineTable(key:), path:)
  }
  let state = case inline_table_bare_values_ok(node.children) {
    True -> state
    False ->
      push_error(state:, kind: types.InvalidBareValueInInlineTable, path:)
  }
  case inline_table_commas_ok(node.children) {
    True -> state
    False ->
      push_error(state:, kind: types.MisplacedInlineTableSeparator, path:)
  }
}

fn check_key_tokens_ok(kv: Node(TomlKind)) -> Bool {
  do_check_key_tokens_ok(kv.children, False)
}

fn do_check_key_tokens_ok(
  children: List(Element(TomlKind)),
  seen_key: Bool,
) -> Bool {
  case children {
    [] -> seen_key
    [T(Token(kind: types.Equals, ..)), ..] -> seen_key
    [T(Token(kind: types.Whitespace, ..)), ..rest] ->
      do_check_key_tokens_ok(rest, seen_key)
    [T(Token(kind: types.Dot, ..)), ..rest] ->
      case seen_key {
        True -> do_check_key_tokens_ok(rest, False)
        False -> False
      }
    [T(Token(kind: types.BareKey, text: text)), ..rest] ->
      case seen_key {
        True -> False
        False ->
          case utils.is_bare_key(text) {
            True -> do_check_key_tokens_ok(rest, True)
            False -> False
          }
      }
    [T(Token(kind: types.Integer, ..)), ..rest]
    | [T(Token(kind: types.BasicString, ..)), ..rest]
    | [T(Token(kind: types.LiteralString, ..)), ..rest] ->
      case seen_key {
        True -> False
        False -> do_check_key_tokens_ok(rest, True)
      }
    [N(n), ..rest] if n.kind == types.Key -> {
      case check_key_tokens_ok(n) {
        True -> do_check_key_tokens_ok(rest, True)
        False -> False
      }
    }
    _ -> False
  }
}

fn has_value(value_tokens: List(Element(TomlKind))) -> Bool {
  list.any(value_tokens, fn(el) {
    case el {
      T(Token(kind: types.Whitespace, ..))
      | T(Token(kind: types.Newline, ..))
      | T(Token(kind: types.Comment, ..))
      | T(Token(kind: types.Equals, ..)) -> False
      _ -> True
    }
  })
}

fn has_extra_equals(value_tokens: List(Element(TomlKind))) -> Bool {
  list.any(value_tokens, fn(el) {
    case el {
      T(Token(kind: types.Equals, ..)) -> True
      _ -> False
    }
  })
}

fn has_single_value(value_tokens: List(Element(TomlKind))) -> Bool {
  do_has_single_value(value_tokens, False)
}

fn do_has_single_value(
  children: List(Element(TomlKind)),
  saw_value: Bool,
) -> Bool {
  case children {
    [] -> True
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest]
    | [T(Token(kind: types.Comment, ..)), ..rest]
    | [T(Token(kind: types.Comma, ..)), ..rest] ->
      do_has_single_value(rest, saw_value)
    [_, ..rest] -> {
      use <- bool.guard(saw_value, return: False)
      do_has_single_value(rest, True)
    }
  }
}

fn check_table_bracket_shape_ok(
  children: List(Element(TomlKind)),
  expected: Int,
) -> Bool {
  let children = elements.skip_trivia(children)
  case
    consume_brackets_ok(children:, count: expected, bracket: types.LeftBracket)
  {
    Error(Nil) -> False
    Ok(rest) -> {
      let #(key_tokens, children) = take_until_right_bracket(rest, [])

      use <- bool.guard(!check_header_key_tokens_ok(key_tokens), return: False)

      consume_brackets_ok(
        children:,
        count: expected,
        bracket: types.RightBracket,
      )
      |> result.map(only_trailing_trivia)
      |> result.unwrap(False)
    }
  }
}

fn consume_brackets_ok(
  children children: List(Element(TomlKind)),
  count count: Int,
  bracket bracket: TomlKind,
) -> Result(List(Element(TomlKind)), Nil) {
  use <- bool.guard(count == 0, return: Ok(children))

  case children {
    [T(Token(kind: k, ..)), ..children] if k == bracket ->
      consume_brackets_ok(children:, count: count - 1, bracket:)
    _ -> Error(Nil)
  }
}

fn take_until_right_bracket(
  children: List(Element(TomlKind)),
  acc: List(Element(TomlKind)),
) -> #(List(Element(TomlKind)), List(Element(TomlKind))) {
  case children {
    [] -> #(list.reverse(acc), [])
    [T(Token(kind: types.RightBracket, ..)), ..] -> #(
      list.reverse(acc),
      children,
    )
    [el, ..rest] -> take_until_right_bracket(rest, [el, ..acc])
  }
}

fn check_header_key_tokens_ok(tokens: List(Element(TomlKind))) -> Bool {
  do_check_header_keys_ok(tokens, False)
}

fn do_check_header_keys_ok(
  tokens: List(Element(TomlKind)),
  seen_key: Bool,
) -> Bool {
  case tokens {
    [] -> seen_key
    [T(Token(kind: types.Whitespace, ..)), ..rest] ->
      do_check_header_keys_ok(rest, seen_key)
    [T(Token(kind: types.Dot, ..)), ..rest] -> {
      use <- bool.guard(!seen_key, return: False)
      do_check_header_keys_ok(rest, False)
    }
    [T(Token(kind: types.BareKey, text: text)), ..rest] -> {
      use <- bool.guard(seen_key, return: False)
      use <- bool.guard(!utils.is_bare_key(text), return: False)
      do_check_header_keys_ok(rest, True)
    }
    [T(Token(kind: types.BasicString, ..)), ..rest]
    | [T(Token(kind: types.LiteralString, ..)), ..rest]
    | [T(Token(kind: types.Integer, ..)), ..rest] -> {
      use <- bool.guard(seen_key, return: False)
      do_check_header_keys_ok(rest, True)
    }
    _ -> False
  }
}

fn only_trailing_trivia(children: List(Element(TomlKind))) -> Bool {
  case children {
    [] -> True
    [T(Token(kind: types.Newline, ..)), ..] -> True
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Comment, ..)), ..rest] -> only_trailing_trivia(rest)
    _ -> False
  }
}

fn array_is_closed(children: List(Element(TomlKind))) -> Bool {
  list.any(children, fn(el) {
    case el {
      T(Token(kind: types.RightBracket, ..)) -> True
      _ -> False
    }
  })
}

fn array_separators_ok(children: List(Element(TomlKind))) -> Bool {
  do_array_seps_ok(children)
}

fn do_array_seps_ok(children: List(Element(TomlKind))) -> Bool {
  case children {
    [] -> True
    [T(Token(kind: types.RightBracket, ..)), ..] -> True
    [T(Token(kind: types.LeftBracket, ..)), ..rest] -> do_array_seps_ok(rest)
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest]
    | [T(Token(kind: types.Comment, ..)), ..rest] -> do_array_seps_ok(rest)
    [N(n), ..rest] if n.kind == types.ArrayElement -> {
      use <- bool.guard(!element_has_single_value(n.children), return: False)
      do_array_seps_ok(rest)
    }
    [T(Token(kind: types.Comma, ..)), ..] -> False
    [_, ..] -> False
  }
}

fn element_has_single_value(children: List(Element(TomlKind))) -> Bool {
  do_element_value_count(children, 0)
}

fn do_element_value_count(
  children: List(Element(TomlKind)),
  count: Int,
) -> Bool {
  case children {
    [] -> count == 1
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest]
    | [T(Token(kind: types.Comment, ..)), ..rest]
    | [T(Token(kind: types.Comma, ..)), ..rest] ->
      do_element_value_count(rest, count)
    [_, ..rest] -> do_element_value_count(rest, count + 1)
  }
}

fn inline_table_is_closed(children: List(Element(TomlKind))) -> Bool {
  list.any(children, fn(el) {
    case el {
      T(Token(kind: types.RightBrace, ..)) -> True
      _ -> False
    }
  })
}

fn inline_table_commas_ok(children: List(Element(TomlKind))) -> Bool {
  do_inline_commas_ok(children, False)
}

fn do_inline_commas_ok(
  children: List(Element(TomlKind)),
  seen_entry: Bool,
) -> Bool {
  case children {
    [] -> True
    [T(Token(kind: types.LeftBrace, ..)), ..rest] ->
      do_inline_commas_ok(rest, False)
    [T(Token(kind: types.RightBrace, ..)), ..rest] ->
      do_inline_commas_ok(rest, False)
    [T(Token(kind: types.Comma, ..)), ..rest] ->
      case seen_entry {
        True -> do_inline_commas_ok(rest, False)
        False -> False
      }
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest]
    | [T(Token(kind: types.Comment, ..)), ..rest] ->
      do_inline_commas_ok(rest, seen_entry)
    [_, ..rest] -> do_inline_commas_ok(rest, True)
  }
}

fn inline_table_bare_values_ok(children: List(Element(TomlKind))) -> Bool {
  do_inline_bare_ok(children, False)
}

fn do_inline_bare_ok(
  children: List(Element(TomlKind)),
  after_eq: Bool,
) -> Bool {
  case children {
    [] -> True
    [T(Token(kind: types.Equals, ..)), ..rest] -> do_inline_bare_ok(rest, True)
    [T(Token(kind: types.Comma, ..)), ..rest] -> do_inline_bare_ok(rest, False)
    [T(Token(kind: types.InvalidValue, ..)), ..] -> False
    [T(Token(kind: types.InvalidBasicString, ..)), ..] -> False
    [T(Token(kind: types.InvalidLiteralString, ..)), ..] -> False
    [T(Token(kind: types.InvalidMultilineBasicString, ..)), ..] -> False
    [T(Token(kind: types.InvalidMultilineLiteralString, ..)), ..] -> False
    [T(Token(kind: types.BareKey, ..)), ..] if after_eq -> False
    [_, ..rest] -> do_inline_bare_ok(rest, after_eq)
  }
}

/// Returns the first conflicting key encountered inside an inline table, if
/// any. Reuses `register_kv_path` against a synthetic state so the same
/// scoping logic that catches duplicates at table level catches them inside
/// inline tables.
fn inline_table_first_duplicate_key(
  children: List(Element(TomlKind)),
) -> option.Option(String) {
  let key_paths = extract_inline_key_paths(children, [])
  let state =
    State(
      collector: enrich_collector(),
      acc: [],
      pos: Pos(line: 0, col: 0, offset: 0),
      path: [],
      path_stack: [],
      paths: dict.new(),
      array_counts: dict.new(),
      value_depth: 0,
    )
  let state =
    list.fold(key_paths, state, fn(state, segments) {
      register_kv_path(
        state:,
        table_path: [],
        segments:,
        value_kind: ScalarValue,
      )
    })
  list.reverse(state.acc)
  |> list.find_map(fn(err) {
    case err.kind {
      types.DuplicateKey(key:, ..)
      | types.KeyIsScalar(key:, ..)
      | types.KeyIsInlineTable(key:, ..)
      | types.KeyIsArray(key:, ..) -> Ok(key)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn extract_inline_key_paths(
  children: List(Element(TomlKind)),
  acc: List(List(String)),
) -> List(List(String)) {
  case elements.skip_all_trivia(children) {
    [] -> list.reverse(acc)
    [T(Token(kind: types.LeftBrace, ..)), ..rest] ->
      extract_inline_key_paths(rest, acc)
    [T(Token(kind: types.RightBrace, ..)), ..] -> list.reverse(acc)
    [T(Token(kind: types.Comma, ..)), ..rest] ->
      extract_inline_key_paths(rest, acc)
    [N(n), ..rest] if n.kind == types.KeyValue -> {
      case take_inline_key_segments_from_kv(n.children, []) {
        [] -> extract_inline_key_paths(rest, acc)
        segments -> extract_inline_key_paths(rest, [segments, ..acc])
      }
    }
    rest -> {
      let #(segments, after_key) = take_inline_key_segments(rest, [])
      let after_eq = skip_to_equals_value(after_key)
      let after_value = skip_inline_value(after_eq)
      case segments {
        [] -> extract_inline_key_paths(after_value, acc)
        _ -> extract_inline_key_paths(after_value, [segments, ..acc])
      }
    }
  }
}

fn take_inline_key_segments(
  children: List(Element(TomlKind)),
  acc: List(String),
) -> #(List(String), List(Element(TomlKind))) {
  case elements.skip_all_trivia(children) {
    [] -> #(list.reverse(acc), [])
    [T(Token(kind: types.Equals, ..)), ..] as rest -> #(list.reverse(acc), rest)
    [T(Token(kind: types.BareKey, text: text)), ..rest] -> {
      let segs = string.split(text, ".") |> list.filter(fn(s) { s != "" })
      take_inline_key_segments(rest, list.append(list.reverse(segs), acc))
    }
    [T(Token(kind: types.Integer, text: text)), ..rest] ->
      take_inline_key_segments(rest, [text, ..acc])
    [T(Token(kind: types.BasicString, text: text)), ..rest] ->
      take_inline_key_segments(rest, [utils.unescape_basic_string(text), ..acc])
    [T(Token(kind: types.LiteralString, text: text)), ..rest] ->
      take_inline_key_segments(rest, [text, ..acc])
    [T(Token(kind: types.Dot, ..)), ..rest] ->
      take_inline_key_segments(rest, acc)
    [_, ..rest] -> take_inline_key_segments(rest, acc)
  }
}

fn take_inline_key_segments_from_kv(
  children: List(Element(TomlKind)),
  acc: List(String),
) -> List(String) {
  case children {
    [] -> list.reverse(acc)
    [T(Token(kind: types.Equals, ..)), ..] -> list.reverse(acc)
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Dot, ..)), ..rest] ->
      take_inline_key_segments_from_kv(rest, acc)
    [T(Token(kind: types.BareKey, text:)), ..rest] ->
      take_inline_key_segments_from_kv(rest, [text, ..acc])
    [T(Token(kind: types.Integer, text:)), ..rest] ->
      take_inline_key_segments_from_kv(rest, [text, ..acc])
    [T(Token(kind: types.BasicString, text:)), ..rest] ->
      take_inline_key_segments_from_kv(rest, [
        utils.unescape_basic_string(text),
        ..acc
      ])
    [T(Token(kind: types.LiteralString, text:)), ..rest] ->
      take_inline_key_segments_from_kv(rest, [text, ..acc])
    [_, ..rest] -> take_inline_key_segments_from_kv(rest, acc)
  }
}

fn skip_to_equals_value(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case children {
    [] -> []
    [T(Token(kind: types.Equals, ..)), ..rest] -> rest
    [_, ..rest] -> skip_to_equals_value(rest)
  }
}

fn skip_inline_value(
  children: List(Element(TomlKind)),
) -> List(Element(TomlKind)) {
  case elements.skip_all_trivia(children) {
    [] -> []
    [N(_), ..rest] -> rest
    [T(_), ..rest] -> rest
  }
}

fn list_init(l: List(String)) -> List(String) {
  case l {
    [] -> []
    [_] -> []
    _ -> list.take(l, list.length(l) - 1)
  }
}

fn last_or_empty(l: List(String)) -> String {
  list.last(l) |> result.unwrap("")
}
