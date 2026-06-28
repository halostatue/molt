//// Shared types for molt, molt/cst, molt/ops, and molt/value.

// Implementation notes:
//
// TomlKind is the TOML node and token kinds for building the greenwood CST,
// covering TOML 1.0 and 1.1 syntax elements. Node kinds represent the tree
// structure and token kinds represent leaf node text.
//
// Molt takes some liberties with the "green token" approach provided by
// greenwood as compared to the Rowan (rust-analyzer) and Roslyn (.NET)
// approaches. Fixed text tokens (such as `Equal` → `=` and `LeftBracket` → `[`)
// store the empty string for the `text` value (the token `kind` is always
// sufficient for reconstruction). TOML strings (there are four types) store the
// _contents_ of the string not including the string delimiters.
//
// This simplifies internal operations and representations for both CST
// manipulation (`molt/cst`) and semantic manipulation (`molt`). It does
// require the use of specific emitter functions for reconstruction, but as
// Molt parses all documents as TOML 1.1 and will emit as TOML 1.0 on
// demand, the emitter functions are required regardless.

import gleam/dict.{type Dict}
import gleam/option.{type Option}
import greenwood.{type Node}

/// A path addressing a node in the document, a list of path segments.
pub type Path =
  List(PathSegment)

/// A segment in a document path.
pub type PathSegment {
  /// A key name.
  KeySegment(String)
  /// A zero-based index into an array or array table. Negative counts from end.
  IndexSegment(Int)
}

/// The TOML spec version to be supported.
pub opaque type TomlVersion {
  TomlVersion(String)
}

/// The full indexed structure for a TOML document.
///
/// The TOML document CST keeps keys flat (`[a.b.c]` refers to a table node at
/// `a.b.c`). When logically manipulating a document, it may be necessary to
/// find the implicit table `a.b` to add a sibling to `a.b.c`. This index
/// is built by walking the tree for a document.
///
/// #### Example
///
/// ```toml
/// first = "first"
///
/// [one.two]
/// three = 3
///
/// [[foo.bar]]
/// baz = "hoge"
///
/// [[foo.bar]]
/// baz = "quux"
/// ```
///
/// This will have a document index like:
///
/// - `first`: `IndexScalarValue`
/// - `one`: `IndexImplicitTable`
/// - `one.two`: `IndexTable`
/// - `one.two.three`: `IndexScalarValue`
/// - `foo`: `IndexImplicitTable`
/// - `foo.bar`: `IndexArrayOfTables(2)`
/// - `foo.bar[0].baz`: `IndexScalarValue`
/// - `foo.bar[1].baz: `IndexScalarValue`
@internal
pub type DocumentIndex =
  Dict(IndexKey, IndexEntry)

/// TOML document index value types.
///
/// The first three index variants (table, array table, and implicit table) are
/// items referenced via header keys (`[a.b.c]`, `[[a.b.c]]`). The last three
/// index variants refer to items assigned to a bare key (`a.b.c = 3`,
/// `c = [3]` in a table `[a.b]`).
@internal
pub type IndexEntry {
  IndexTable(children: List(String))
  IndexArrayOfTables(count: Int, children: List(String))
  IndexArrayOfTablesEntry(parent: Path, index: Int, children: List(String))
  IndexImplicitTable(children: List(String))
  IndexScalarValue(container: Path)
  IndexInlineTableValue(container: Path)
  IndexArrayValue(container: Path)
}

/// A position in the source document.
pub type Span {
  Span(line: Int, col: Int, offset: Int)
}

/// Parse error variants are organised into four broad groups:
///
/// 1. Path duplicates, where a key or table is defined more than once;
/// 2. Path traversal errors, where a key or table definition crosses
///    a non-table value;
/// 3. Structural syntax errors when the produced tokens cannot represent part
///    any valid TOML structure;
/// 4. Other errors including unparsable content.
///
/// When `SyntaxErrorKind` variants have an `original` Span, this always refers
/// to the original declaration and the Span in the `SyntaxError` refers to the
/// current instance.
pub type SyntaxErrorKind {
  /// A key was declared twice within the same table scope.
  DuplicateKey(key: String, original: Span)
  /// A `[table]` or `[[array of tables]]` header collides with an existing
  /// explicit table or array of tables definition.
  DuplicateTable(original: Span)

  /// A dotted key or table header tries to descend through an ancestor key
  /// that is bound to a scalar value (`a = 1` then `a.b = 2`, or `[a.b]`).
  KeyIsScalar(key: String, original: Span)
  /// A dotted key or table header tries to descend through an ancestor key
  /// that is bound to an inline table (`a = { b = 1 }` then `a.c = 2`).
  KeyIsInlineTable(key: String, original: Span)
  /// A dotted key or table header tries to descend through an ancestor key
  /// that is bound to an inline array (`a = [1, 2]` then `a.b = 3`).
  KeyIsArray(key: String, original: Span)

  /// A key uses a syntax the spec does not allow (bare-key with invalid
  /// characters, missing/extra dots, etc.).
  InvalidKeySyntax

  /// A key/value pair with no value: `key =`. In TOML, values must begin on the
  /// same line as the key and equals sign.
  MissingValue
  /// A key/value pair with more than one `=`: `key = = 1`.
  ExtraEquals
  /// A key/value pair with more than one value: `key = 1 2`.
  MultipleValues

  /// An empty table header: `[]` or `[[]]`.
  EmptyTableHeader
  /// A table header with mismatched brackets, invalid key tokens inside the
  /// brackets, or trailing junk after the closing bracket.
  MalformedTableHeader

  /// An array opened with `[` but not closed before end of document. Because
  /// the array scanner consumes subsequent lines until it finds a closing `]`
  /// or runs out of source, **all document content after the opening `[` is
  /// structurally broken**: table headers and key/value pairs that follow are
  /// misclassified as array elements and appear as additional `BadValue` errors
  /// rather than as addressable nodes. This error requires manual correction
  /// before any index-based operations can be performed on the affected region.
  UnterminatedArray
  /// Misplaced/missing/extra commas between array elements.
  MisplacedArraySeparator

  /// An inline table opened with `{` but not closed before end-of-line.
  ///
  /// All content on subsequent lines is consumed as inline table entries and
  /// misclassified, producing cascading `BadValue` errors. Like
  /// `UnterminatedArray`, this requires manual correction before index-based
  /// operations are reliable past the opening `{`.
  UnterminatedInlineTable
  /// A key declared more than once inside an inline table.
  DuplicateKeyInInlineTable(key: String)
  /// An entry inside an inline table that's missing its `=` (a bare key or
  /// value with no key/value structure).
  InvalidBareValueInInlineTable
  /// Misplaced, missing, or extra commas in an inline table.
  MisplacedInlineTableSeparator

  /// A basic (`"`) or literal (`'`) string that was not closed before
  /// end-of-line. The rest of the document is unaffected and other operations
  /// on the CST remain valid.
  UnterminatedString
  /// A multiline basic (`"""`) or literal (`'''`) string that was not closed
  /// before end of document. Because the multiline scanner consumes input until
  /// it finds the closing delimiter or runs out of source, **all document
  /// content after the opening delimiter is lost from the CST**. This error
  /// should be reported to the user as requiring manual correction before any
  /// further operations can be performed.
  UnterminatedMultilineString
  /// An unclassifiable token in value position.
  BadValue(text: String)
  /// Content that the parser couldn't make sense of (Error node in CST).
  UnparsableContent
  /// The source has non-trivia content but no recognisable TOML structure
  /// (e.g. no `=` and no `[`).
  NoValidTomlStructure
}

/// A recoverable error found during parsing or validation. These do not prevent
/// CST construction but block index-building and high-level operations.
pub type SyntaxError {
  SyntaxError(kind: SyntaxErrorKind, path: List(String), span: Span)
}

/// A parsed TOML document.
///
/// Produced by `molt.parse` and operated on by most other molt
/// functions.
///
/// The `version` field controls how the document is output, see
/// `molt.set_version`.
///
/// `error_count` is the number of validation errors found in the document.
/// It must be zero before most document-level functions can operate. Inspect it
/// with `molt.has_errors` / `molt.error_count`, or retrieve the full list of
/// positioned errors with `molt.document_errors`.
///
/// The `tree` and `index` fields are internal and should not be accessed
/// directly; use `molt/cst` for direct tree operations.
pub type Document {
  Document(
    version: TomlVersion,
    error_count: Int,
    tree: Node(TomlKind),
    index: Option(DocumentIndex),
  )
}

/// TOML Parser kinds for the concrete syntax tree.
pub type TomlKind {
  // Node kinds: interior tree nodes that contain children.
  /// Root document node.
  ///
  /// `node`
  Root
  /// A standard table header: `[path.to.table]`
  ///
  /// `node`
  Table
  /// An array of tables header: `[[path.to.array]]`
  ///
  /// `node`
  ArrayOfTables
  /// A key/value pair: `key = value`
  ///
  /// `node`
  KeyValue
  /// A dotted key path: `a.b.c`
  ///
  /// `node`
  Key
  /// An array value: `[1, 2, 3]`
  ///
  /// `node`
  Array
  /// An inline table value: `{a = 1, b = 2}`
  ///
  /// `node`
  InlineTable
  /// A single element within an array, carrying its value and associated
  /// trivia (comments).
  ///
  /// `node`
  ArrayElement
  /// Unparsable content: the parser couldn't make sense of this.
  ///
  /// `node`
  Error
  /// Document tail: a tombstone node holding any trivia (comments / blank lines)
  /// that dangles after the final statement. Like `Root`, it carries leading
  /// trivia only and emits no content of its own; it exists so document-tail
  /// comments have a node to attach to (`get_document_comments(_, Tail)`).
  ///
  /// Tail comments are stored in this position after all value nodes. When
  /// rendered, a newline _may_ be placed between the final value node and these
  /// comments: a parsed tail keeps the source's spacing, while setting the tail
  /// (and normalizing) always separates it from the content with a blank line.
  ///
  /// `node`
  PostScript

  // Token kinds: leaf nodes carrying literal source text.
  /// UTF-8 Byte Order Mark at the start of a file
  ///
  /// `token`
  Bom
  /// A bare key: `my-key`, `key123`
  ///
  /// `token`
  BareKey
  /// An unclassifiable token in value position
  ///
  /// `token`
  InvalidValue
  /// An unterminated or otherwise invalid basic string: `"hello\n`
  ///
  /// `token`
  InvalidBasicString
  /// An unterminated or otherwise invalid literal string: `'hello\n`
  ///
  /// `token`
  InvalidLiteralString
  /// An unterminated or otherwise invalid multiline basic string: `"""...`
  ///
  /// `token`
  InvalidMultilineBasicString
  /// An unterminated or otherwise invalid multiline literal string: `'''...`
  ///
  /// `token`
  InvalidMultilineLiteralString
  /// A basic (double-quoted) string used as key or value: `"hello"`
  ///
  /// `token`
  BasicString
  /// A multi-line basic string with no newline after the opening delimiter:
  /// `"""..."""`. The text field stores the raw content without delimiters.
  ///
  /// `token`
  MultilineBasicString
  /// A multi-line basic string with a newline immediately after the opening
  /// delimiter: `"""\n..."""`. The text field stores the raw content without
  /// delimiters or the leading newline (which is encoded in the kind itself).
  ///
  /// `token`
  MultilineBasicStringNl
  /// A literal (single-quoted) string used as key or value: `'hello'`
  ///
  /// `token`
  LiteralString
  /// A multi-line literal string with no newline after the opening delimiter:
  /// `'''...'''`. The text field stores the raw content without delimiters.
  ///
  /// `token`
  MultilineLiteralString
  /// A multi-line literal string with a newline immediately after the opening
  /// delimiter: `'''\n...'''`. The text field stores the raw content without
  /// delimiters or the leading newline (which is encoded in the kind itself).
  ///
  /// `token`
  MultilineLiteralStringNl
  /// A decimal integer value
  ///
  /// `token`
  Integer
  /// A binary integer value
  ///
  /// `token`
  BinaryInteger
  /// A hex integer value
  ///
  /// `token`
  HexInteger
  /// An octal integer value
  ///
  /// `token`
  OctalInteger
  /// A floating-point value
  ///
  /// `token`
  Float
  /// A boolean `true` value.
  ///
  /// `token`
  BoolTrue
  /// A boolean `false` value.
  ///
  /// `token`
  BoolFalse
  /// A floating point Infinity value (`inf`).
  ///
  /// `token`
  Inf
  /// A floating point positive Infinity value (`+inf`).
  ///
  /// `token`
  PosInf
  /// A floating point negative Infinity value (`-inf`).
  ///
  /// `token`
  NegInf
  /// A floating point NaN value (`nan`).
  ///
  /// `token`
  NaN
  /// A floating point positive NaN value (`+nan`).
  ///
  /// `token`
  PosNaN
  /// A floating point negative NaN value (`-nan`).
  ///
  /// `token`
  NegNaN
  /// An offset date-time
  ///
  /// `token`
  OffsetDateTime
  /// A local date-time
  ///
  /// `token`
  LocalDateTime
  /// A local date
  ///
  /// `token`
  LocalDate
  /// A local time
  ///
  /// `token`
  LocalTime
  /// `=`
  ///
  /// `token`
  Equals
  /// `.`
  ///
  /// `token`
  Dot
  /// `,`
  ///
  /// `token`
  Comma
  /// `[`
  ///
  /// `token`
  LeftBracket
  /// `]`
  ///
  /// `token`
  RightBracket
  /// `{`
  ///
  /// `token`
  LeftBrace
  /// `}`
  ///
  /// `token`
  RightBrace
  /// A comment: `# ...` (includes the `#`)
  ///
  /// `token`
  Comment
  /// Whitespace (spaces and tabs: not newlines)
  ///
  /// `token`
  Whitespace
  /// A newline: `\n` or `\r\n`
  ///
  /// `token`
  Newline
}

/// Marks a document as TOML 1.0 for output.
pub const v1_0 = TomlVersion("1.0")

/// Marks a document as TOML 1.1 for output.
pub const v1_1 = TomlVersion("1.1")

@internal
pub type IndexKey {
  IndexKey(Path)
}
