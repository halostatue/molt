//// molt: TOML manipulation kit
////
//// Molt parses a TOML document into a concrete syntax representation that
//// can be transformed and rewritten while preserving comments associated with
//// nodes.
////
//// ## Path Syntax
////
//// Molt functions and operations accept a path string made up of key
//// segments separated by `.` (like `a.b`) and array indexes in brackets
//// (like `[0]` or `[-1]`).
////
//// Bare key segments may contain ASCII letters, digits, underscores, and
//// dashes. Segments requiring other characters (such as spaces or dots) must
//// be quoted with single quotes (no escape processing) or double quotes (with
//// escape processing, e.g. `\"`).
////
//// ```
//// a.b.c.d                   // ["a", "b", "c", "d"]
//// a.b.-1.d                  // ["a", "b", "-1", "d"]
//// a.b."with space".'[3]'    // ["a", "b", "with space", "[3]"]
//// a.b."\e".'\e'             // ["a", "b", "\u{001b}", "\\e"]
//// ```
////
//// Array indexes must be integer values within brackets and negative indexing
//// is supported. `0` is the first value in an array or array of tables, `-1` is
//// the last value in an array or array of tables.
////
//// ```
//// a.b[-1].c                 // ["a", "b", -1, "c"]
//// a.b[3].c                  // ["a", "b", 3, "c"]
//// ```
////
//// Path resolution behaviour with key or index values that do not resolve to
//// a logical entry in the document depends on the operation performed.
////
//// When operations are required against the document root, use an empty path
//// string (`""`).
////
//// The `InvalidPath` variant of `MoltError` will be returned from
//// `molt` functions if the path syntax is invalid.
////
//// In some contexts, _only_ key paths may be provided.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import greenwood
import molt/cst
import molt/error.{type MoltError}
import molt/internal/document
import molt/internal/document/comments
import molt/internal/document/index
import molt/internal/emitter
import molt/internal/parser
import molt/internal/path as path_
import molt/internal/utils
import molt/internal/validate
import molt/ops.{type Operation}
import molt/types.{
  type Document, type DocumentIndex, type Path as Path, type PathSegment,
  type TomlKind, Document, IndexSegment, KeySegment,
}
import molt/value.{type Value}

/// TOML 1.0
pub const v1_0 = types.v1_0

/// TOML 1.1
pub const v1_1 = types.v1_1

/// Create an empty TOML document.
pub fn new() -> Document {
  Document(
    tree: greenwood.node(types.Root, []),
    version: v1_1,
    index: Some(dict.new()),
    error_count: 0,
  )
}

/// Parse a TOML source string into a `Document`.
///
/// Returns an error if the the document _cannot_ be parsed. Note that most
/// documents can be parsed, but not all documents with errors produce usable or
/// easily recoverable syntax trees.
///
/// The document's `error_count` records how many validation errors were found;
/// retrieve the full positioned list with `document_errors`.
///
/// The parsed document defaults to TOML 1.1 format, even if the source file was
/// TOML 1.0.
pub fn parse(source: String) -> Result(Document, MoltError) {
  use tree <- result.try(parser.parse(source))

  let error_count = validate.count(tree)

  Ok(Document(tree:, version: v1_1, index: None, error_count:))
}

/// Parses a TOML source `BitArray` into a `Document`.
///
/// Returns an error if the source is not valid UTF-8 data or if the transformed
/// UTF-8 data fails on `parse`.
pub fn parse_bits(source: BitArray) -> Result(Document, MoltError) {
  use source <- result.try(safe_bits_to_string(source))
  parse(source)
}

/// Every validation error in the document as a fully-positioned `SyntaxError`,
/// computed on demand from the current tree. Returns `[]` for a valid document.
///
/// This is the only path that builds error spans; parsing and construction only
/// count, so positions are paid for solely when you ask for them here.
pub fn document_errors(doc: Document) -> List(types.SyntaxError) {
  validate.enrich(doc.tree)
}

/// Whether the document has any validation errors. Most document-level
/// operations refuse to run while this is `True`.
pub fn has_errors(doc: Document) -> Bool {
  doc.error_count > 0
}

/// The number of validation errors found in the document.
pub fn error_count(doc: Document) -> Int {
  doc.error_count
}

/// Generate a TOML string from the document.
///
/// If the document version is the same as the original version and no changes
/// have been made, the original document will be reproduced exactly.
pub fn to_string(doc: Document) -> String {
  emitter.emit_versioned(doc.tree, doc.version)
}

/// Outputs a `normalize`d version of the document as a string.
pub fn to_normalized_string(doc doc: Document) -> String {
  doc |> normalize |> to_string
}

/// Returns a copy of the document with its tree normalized:
///
/// - Unix newlines (LF) throughout.
/// - Table header declarations have excess leading and interior space removed.
/// - Key/value pairs have excess leading space removed, a single space after
///   the key and a single space before the value, resulting in `key = value`.
/// - A single blank line separates table and array of tables headers.
/// - Leading comments are preserved immediately before their node.
/// - Trailing (inline) comments on key-value and header lines are preserved.
/// - Inline arrays and tables without comments are collapsed to a single-line
///   form.
/// - The document ends with a single trailing newline.
///
/// The returned document is valid for further operations or for piping into
/// `to_string`.
pub fn normalize(doc doc: Document) -> Document {
  Document(..doc, tree: emitter.normalize(doc.tree))
}

/// Execute a batch of `Operation`s over a `Document` where all operations must
/// succeed for an update.
///
/// `Operation`s will not run over a `Document` with errors.
pub fn run(
  doc doc: Document,
  ops ops: List(Operation),
) -> Result(Document, MoltError) {
  list.try_fold(ops, doc, document.run)
}

/// Appends to an array at `path`.
///
/// `path` must resolve to either a value node containing an array or an array
/// of tables. When `path` resolves to an array of tables, the `value`
/// provided _must_ be table-like.
pub fn append(
  doc doc: Document,
  path path: String,
  value value: Value,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Append(path:, value:)])
}

/// Concatenate multiple values to an array at `path`.
///
/// `path` must resolve to either a value node containing an array or an array
/// of tables. When `path` resolves to an array of tables, all entries in
/// `values` _must_ be table-like.
pub fn concat(
  doc doc: Document,
  path path: String,
  values values: List(Value),
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Concat(path:, values:)])
}

/// Ensures that a table or array of tables exists at `path`.
///
/// `kind` must be `types.Table` or `types.ArrayOfTables`; other kinds are
/// rejected.
///
/// If the matching structure already exists, nothing is done. If `path` does
/// not resolve, an empty entry is created with implicit table ancestors as
/// required. If `path` resolves to an implicit table and `kind` is
/// `types.Table`, the implicit table is concretized into an emitted header
/// using the key segments of `path`.
///
/// A `TypeMismatch` error is returned if `path` resolves to any other value
/// shape, or if any ancestor in the `path` is anything other than an implicit
/// table, concrete table, or array of tables entry.
pub fn ensure_exists(
  doc doc: Document,
  path path: String,
  kind kind: TomlKind,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.EnsureExists(path:, kind:)])
}

/// Get the value or structure at `path` as a molt Value.
///
/// Implicit tables are returned as table values.
pub fn get(doc doc: Document, path path: String) -> Result(Value, MoltError) {
  use path <- result.try(path_.parse(path))

  case path {
    [] -> get_root_as_value(doc:)
    _ -> {
      use idx <- index.with_index(doc)
      get_value_by_index(doc:, idx:, path:)
    }
  }
}

/// Reads the comments attached to the node at `path`.
///
/// `path` must resolve to a concrete node (not an implicit table) or the root
/// of the document (`""`); other paths return an error.
///
/// The result mirrors `set_comments`: leading comment lines and an optional
/// trailing (inline) comment. Comment text is returned verbatim, including the
/// leading `#`, so a value read here round-trips back through `set_comments`
/// unchanged.
pub fn get_comments(
  doc doc: Document,
  path path: String,
) -> Result(ops.Comments, MoltError) {
  comments.get_comments(doc:, path:)
}

pub type DocumentCommentPosition {
  /// Document header comments are stored in this position before any value
  /// node. When rendered, a blank line will be placed between these comments
  /// and the first value node.
  Header
  /// Document trailer comments are stored in this position after all value
  /// nodes. When rendered, a newline _may_ be placed between the final value
  /// node and these comments.
  Trailer
}

/// Reads `Header` or `Trailer` document comments.
///
/// Returns the comment lines verbatim (including the leading `#` but without
/// newlines) or `[]` when there are no comments.
pub fn get_document_comments(
  doc doc: Document,
  at at: DocumentCommentPosition,
) -> List(String) {
  case at {
    Header -> cst.document_head_comments(doc.tree)
    Trailer -> cst.document_tail_comments(doc.tree)
  }
}

/// Replaces `Header` or `Trailer` document comments, returning the updated
/// document. If the comment text does not include `#`, the comment text will
/// have `# ` prepended. Comments must not include newlines; they will be added
/// appropriately on emit.
///
/// Passing `[]` clears the comments.
pub fn set_document_comments(
  doc doc: Document,
  at at: DocumentCommentPosition,
  comments comments: List(String),
) -> Document {
  let tree = case at {
    Header -> cst.set_document_head_comments(doc.tree, comments)
    Trailer -> cst.set_document_tail_comments(doc.tree, comments)
  }
  // Trivia-only changes don't move any path, but materializing/dropping the
  // PostScript child reshapes Root's children, so invalidate the cached index.
  Document(..doc, tree:, index: None)
}

/// Check if `path` exists in the document.
pub fn has(doc doc: Document, path path: String) -> Bool {
  case path_.parse(path), index.get_index(doc) {
    Ok([]), _ -> True
    Ok(path), Ok(idx) -> {
      let lookup = index.resolve_negative_indices(idx:, path:)
      let key = index.path_to_index_key(lookup)
      use <- bool.guard(index.has_key(idx, key), return: True)

      case index.find_deepest_ancestor_entry(idx, key) {
        Ok(types.IndexScalarValue(..))
        | Ok(types.IndexArrayValue(..))
        | Ok(types.IndexInlineTableValue(..)) ->
          cst.get(node: doc.tree, path: lookup)
          |> result.is_ok
        _ -> False
      }
    }
    _, _ -> False
  }
}

/// Inserts a value before index `before` in an array at `path`.
///
/// `path` must resolve to a value node containing an array or an array of
/// tables. When `path` resolves to an array of tables, `value` must be
/// table-like.
pub fn insert(
  doc doc: Document,
  path path: String,
  before before: Int,
  value value: Value,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Insert(path:, before:, value:)])
}

/// Inserts a key/value pair before an existing key in the table at `path`.
///
/// `path` must resolve to a concrete table, array of tables entry, or
/// implicit table. Both `before` and `key` are literal key names (immediate
/// children of `path`). If `before` is not found, the entry is appended.
///
/// When `path` is an implicit table, the new entry is emitted as a
/// root-level dotted key.
pub fn insert_key(
  doc doc: Document,
  path path: String,
  before before: String,
  key key: String,
  value value: Value,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.InsertKey(path:, before:, key:, value:)])
}

/// Return the list of keys in a table-like value at the provided `path`.
pub fn keys(
  doc doc: Document,
  path p: String,
) -> Result(List(String), MoltError) {
  use segments <- result.try(path_.parse(p))

  use idx <- index.with_index(doc)

  case segments {
    [] -> Ok(index.root_children(idx))
    _ ->
      case index.get_path(idx, segments) {
        Ok(types.IndexTable(children:))
        | Ok(types.IndexImplicitTable(children:))
        | Ok(types.IndexArrayOfTablesEntry(children:, ..)) -> Ok(children)

        Ok(_) ->
          Error(error.TypeMismatch(
            path: Some(path_.to_string(segments)),
            expected: "table, implicit table, or array of tables entry",
            got: "value",
          ))
        Error(Nil) -> Error(error.not_found_path(segments))
      }
  }
}

/// Return the number of entries in an array or array of tables at `path`.
pub fn length(doc doc: Document, path p: String) -> Result(Int, MoltError) {
  use segments <- result.try(path_.parse(p))

  use <- bool.guard(
    segments == [],
    return: Error(error.InvalidOperation("length", None)),
  )

  use idx <- index.with_index(doc)

  case index.get_path(index: idx, path: segments) {
    Ok(types.IndexArrayOfTables(count:, ..)) -> Ok(count)
    Ok(types.IndexArrayValue(..)) -> {
      let #(table_segs, key) = path_.split_last_segment(segments)

      use key_name <- path_.with_segment_key_name(
        key,
        or: Error(error.not_found_path(segments)),
      )
      use val <- result.try(document.get_value(
        doc:,
        at: table_segs,
        key: key_name,
      ))

      value.array_length(val)
      |> option.to_result(error.TypeMismatch(
        path: Some(path_.to_string(segments)),
        expected: "array",
        got: value.type_of(val),
      ))
    }
    Ok(entry) ->
      Error(error.TypeMismatch(
        path: Some(path_.to_string(segments)),
        expected: "array",
        got: utils.index_entry_to_string(entry),
      ))

    Error(Nil) ->
      case path_.split_last_segment(segments) {
        #(parent, IndexSegment(i)) ->
          case index.get_path(index: idx, path: parent) {
            Ok(types.IndexArrayValue(..)) -> {
              let #(table_segs, key) = path_.split_last_segment(parent)
              use key_name <- path_.with_segment_key_name(
                key,
                or: Error(error.not_found_path(segments)),
              )
              use arr <- result.try(document.get_value(
                doc:,
                at: table_segs,
                key: key_name,
              ))
              use items <- result.try(
                value.array_to_list(arr)
                |> result.replace_error(error.not_found_path(segments)),
              )
              let len = list.length(items)
              let resolved = utils.resolve_index(i, len)

              use entry <- result.try(
                utils.list_at(items, resolved)
                |> result.replace_error(error.IndexOutOfRange(
                  path: path_.to_string(parent),
                  index: i,
                  length: len,
                )),
              )

              value.array_length(entry)
              |> option.to_result(error.TypeMismatch(
                path: Some(path_.to_string(segments)),
                expected: "array",
                got: value.type_of(entry),
              ))
            }
            _ -> Error(error.not_found_path(segments))
          }
        _ -> Error(error.not_found_path(segments))
      }
  }
}

/// Merge key/value entries into the resolved table at `path`.
///
/// `path` must resolve to a concrete table or an array of tables entry;
/// implicit tables and other shapes are rejected with a `TypeMismatch` error.
///
/// Each key in `entries` is parsed as a path value relative to the table at
/// `path`. Index segments in entry keys will be rejected with an
/// `InvalidPath` error, and entry keys redefining any existing concrete table
/// or value are rejected.
///
/// The `on_conflict` parameter controls how collisions with existing leaf
/// keys are resolved.
pub fn merge_values(
  doc doc: Document,
  path path: String,
  entries entries: List(#(String, Value)),
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.MergeValues(path:, entries:, on_conflict:)])
}

/// Moves the node at `from` to `to`.
///
/// `from` must resolve to an existing node of any kind except the root. `to`
/// must not already exist, and its last segment must be a key (not an index).
/// The node is removed from `from` and re-inserted at `to`, preserving its
/// structure.
pub fn move(
  doc doc: Document,
  from from: String,
  to to: String,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Move(from:, to:)])
}

/// Moves comments from the node at `from` to the node at `to`.
///
/// Both `from` and `to` must resolve to concrete nodes or the root of the
/// document (`""`).
pub fn move_comments(
  doc doc: Document,
  from from: String,
  to to: String,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.MoveComments(from:, to:)])
}

/// Moves a subset of keys from the table at `from` into the table at `to`.
///
/// `from` must resolve to a concrete table, implicit table, or array of
/// tables entry. `keys` are literal key names naming the immediate children
/// of the `from` table. Keys not present in the `from` table are ignored.
///
/// If `to` does not exist or is an implicit table, a concrete table header
/// will be created. The `on_conflict` parameter controls how collisions
/// with existing keys in the `to` table are resolved.
pub fn move_keys(
  doc doc: Document,
  from from: String,
  to to: String,
  keys keys: List(String),
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.MoveKeys(from:, to:, keys:, on_conflict:)])
}

/// Unconditionally places `value` at `path`.
///
/// If `path` already exists, it is removed before writing the `value`.
/// Structural `Value`s (table, array of tables, etc.) are permitted.
pub fn place(
  doc doc: Document,
  path path: String,
  value value: Value,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Place(path:, value:)])
}

/// Removes the node at `path` from the document.
///
/// If `path` resolves to an implicit table, the implicit table and _all_
/// concrete nodes beneath it are removed.
pub fn remove(
  doc doc: Document,
  path path: String,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Remove(path:)])
}

/// Renames the last segment of `path` to `to`.
///
/// The last segment of `path` must be a key. `to` is a literal key name and
/// must not already exist as a sibling.
///
/// Renaming an implicit table renames all concrete descendants that reference
/// it.
pub fn rename(
  doc doc: Document,
  path path: String,
  to to: String,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Rename(path:, to:)])
}

/// Converts the structure at `path` between inline and block forms.
///
/// `path` must resolve to a table or array of tables. The data is preserved;
/// only the representation changes (inline table ↔ table section, array of
/// inline tables ↔ array of tables entries).
///
/// A `path` that does not reference a convertible structure is
/// a `TypeMismatch`. Conversions that would produce invalid TOML (e.g.,
/// inlining a table with sub-table descendants) are rejected.
pub fn representation(
  doc doc: Document,
  path path: String,
  form form: ops.Form,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Representation(path:, form:)])
}

/// Sets a value at `path` in the document.
///
/// Creates or overwrites a key/value node. If `path` does not exist, it is
/// created (with implicit ancestors as needed). If `path` resolves to an
/// existing value node, the value is replaced.
///
/// If `path` resolves to a structural node (table sections, array of tables,
/// implicit tables), `Set` will return a `TypeMismatch` error.
pub fn set(
  doc doc: Document,
  path path: String,
  value value: Value,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Set(path:, value:)])
}

/// Sets comments on the node at `path`.
///
/// `path` must resolve to a concrete node (not an implicit table) or the root
/// of the document (`""`). Replaces any existing comments on the node with the
/// provided `comments`.
pub fn set_comments(
  doc doc: Document,
  path path: String,
  comments comments: ops.Comments,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.SetComments(path:, comments:)])
}

/// Set the target TOML version for output.
///
/// Parsed documents default to TOML 1.1 (`molt.v1_1`).
pub fn set_version(
  doc doc: Document,
  to version: types.TomlVersion,
) -> Document {
  Document(..doc, version:)
}

/// Transfers all keys from `from` to `to`, then removes `from`.
///
/// `from` must resolve to a concrete or implicit table. `to` will be
/// created as a concrete table if it does not exist. The `on_conflict`
/// parameter controls how collisions with existing keys in `to` are
/// resolved.
pub fn transfer(
  doc doc: Document,
  from from: String,
  to to: String,
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Transfer(from:, to:, on_conflict:)])
}

/// Transforms a value in place via callback.
///
/// `path` must resolve to a scalar, array, or inline table value node.
/// Structural types (concrete tables, implicit tables, array of tables) are
/// rejected with `TypeMismatch`.
///
/// Transforming inline tables or arrays round-trips through `Value`, which
/// loses internal comments and multiline formatting.
pub fn update(
  doc doc: Document,
  path path: String,
  with with: fn(Value) -> Result(Value, MoltError),
) -> Result(Document, MoltError) {
  run(doc:, ops: [ops.Update(path:, with:)])
}

/// Creates a `MoltError` for returning from `Update` callbacks.
///
/// `Update` callbacks must return `Result(Value, MoltError)`. Use this
/// function to signal a failure with a descriptive message.
pub fn update_error(message: String) -> MoltError {
  error.UpdateError(message:)
}

fn get_root_as_value(doc doc: Document) -> Result(Value, MoltError) {
  document.list_keys(doc:, at: [])
  |> result.map(
    list.filter_map(_, fn(k) {
      document.get_value(doc:, at: [], key: k)
      |> result.map(fn(v) { #(k, v) })
      |> result.replace_error(Error(Nil))
    }),
  )
  |> result.unwrap([])
  |> value.from_table_entries
  |> Ok
}

fn get_array_of_tables_entry_value(
  doc doc: Document,
  at segments: Path,
  index index: Int,
) -> Result(Value, MoltError) {
  let entry_path = list.append(segments, [IndexSegment(index)])
  case cst.get(node: doc.tree, path: entry_path) {
    Ok(entry_node) -> {
      let entries =
        cst.list_keys(entry_node)
        |> list.filter_map(fn(k) {
          case cst.get(node: entry_node, path: [KeySegment(k)]) {
            Ok(kv) -> Ok(#(k, value.from_cst(kv)))
            Error(_) -> Error(Nil)
          }
        })
      Ok(value.from_table_entries(entries))
    }
    _ -> Error(error.not_found_path(segments))
  }
}

fn get_array_of_tables_as_value(
  doc doc: Document,
  at segments: Path,
  count count: Int,
) -> Result(Value, MoltError) {
  get_array_of_table_entry(doc:, path: segments, index: 0, count:, acc: [])
  |> value.from_array_of_tables()
}

fn get_array_of_table_entry(
  doc doc: Document,
  path segments: List(PathSegment),
  index index: Int,
  count count: Int,
  acc acc: List(Value),
) -> List(Value) {
  case index >= count {
    True -> list.reverse(acc)
    False ->
      case get_array_of_tables_entry_value(doc:, at: segments, index:) {
        Ok(v) ->
          get_array_of_table_entry(
            doc:,
            path: segments,
            index: index + 1,
            count:,
            acc: [v, ..acc],
          )
        _ ->
          get_array_of_table_entry(
            doc:,
            path: segments,
            index: index + 1,
            count:,
            acc:,
          )
      }
  }
}

fn safe_bits_to_string(source: BitArray) -> Result(String, MoltError) {
  // We save up to two leading BOMs because `bit_array.to_string` goes through
  // a text decoder on JavaScript targets which strips a leading BOM and there
  // are two invalid cases in the TOML suite which fail if we don't preserve
  // this exactly. We don't need more than two for those cases to fail.
  let #(bom_prefix, source) = case source {
    <<239, 187, 191, 239, 187, 191, rest:bytes>> -> #("\u{FEFF}\u{FEFF}", rest)
    <<239, 187, 191, rest:bytes>> -> #("\u{FEFF}", rest)
    _ -> #("", source)
  }

  case bit_array.to_string(source) {
    Ok(source) -> Ok(bom_prefix <> source)
    Error(Nil) -> Error(error.InvalidSourceEncoding)
  }
}

fn get_value_by_index(
  doc doc: Document,
  idx idx: DocumentIndex,
  path segments: Path,
) -> Result(Value, MoltError) {
  // Resolve negative AoT indices to positive for lookup/navigation; `segments`
  // (the caller's original path) is retained for error reporting.
  let lookup = index.resolve_negative_indices(idx:, path: segments)
  let key = index.path_to_index_key(lookup)
  case index.get(idx, key) {
    Ok(types.IndexScalarValue(container:))
    | Ok(types.IndexArrayValue(container:))
    | Ok(types.IndexInlineTableValue(container:)) -> {
      let kv_key = list.drop(lookup, list.length(container))
      case kv_key {
        [KeySegment(_), ..] -> document.get_value_at(doc:, container:, kv_key:)
        _ -> Error(error.not_found_path(segments))
      }
    }
    Ok(types.IndexImplicitTable(children:)) -> {
      let entries =
        list.filter_map(children, fn(k) {
          get_value_by_index(
            doc:,
            idx:,
            path: list.append(lookup, [KeySegment(k)]),
          )
          |> result.map(fn(v) { #(k, v) })
          |> result.replace_error(Nil)
        })
      Ok(value.from_table_entries(entries))
    }
    Ok(types.IndexTable(..)) | Ok(types.IndexArrayOfTablesEntry(..)) -> {
      use node <- result.try(
        cst.get(node: doc.tree, path: lookup)
        |> result.replace_error(error.not_found_path(segments)),
      )

      let entries =
        cst.list_keys(node)
        |> list.filter_map(fn(k) {
          cst.get(node: node, path: [KeySegment(k)])
          |> result.map(fn(kv) { #(k, value.from_cst(kv)) })
          |> result.replace_error(Nil)
        })

      Ok(value.from_table_entries(entries))
    }
    Ok(types.IndexArrayOfTables(count:, ..)) ->
      get_array_of_tables_as_value(doc:, at: lookup, count:)
    Error(Nil) ->
      // Miss: might be descending into a value (including a negative array
      // index, which structural navigation resolves).
      case index.find_deepest_ancestor_entry(idx, key) {
        Ok(types.IndexScalarValue(..))
        | Ok(types.IndexArrayValue(..))
        | Ok(types.IndexInlineTableValue(..)) ->
          cst.get(node: doc.tree, path: lookup)
          |> result.map(value.from_cst)
          |> result.replace_error(error.not_found_path(segments))
        _ -> Error(error.not_found_path(segments))
      }
  }
}
