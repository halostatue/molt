//// molt/ops: Operation types for document manipulation.
////
//// The types declared in this module offer document manipulation options for
//// use in `molt.run` batches.
////
//// ## Path Resolution Targets
////
//// The `path` string provided to operations resolves against a logical version
//// of the document's concrete syntax tree so that implicit nodes and value
//// nodes may be modified. The shape of the targeted document node determines
//// which operations are legal and what side-effects occur.
////
//// - Concrete tables: tables defined by explicit headers, such as `[header]`
////   or `[database.connection]`.
////
//// - Implicit tables: tables whose existence are implied by dotted key or
////   sub-header references. In `[database.connection]`, `database` is an
////   implicit table, as is `package` for a dotted key definition of:
////   `package.type = "gleam"`.
////
//// - Array of tables: a collection of tables identified by `[[name]]` headers.
////   Paths may resolve to the collection by omitting index references
////   (`custom.plugins` referencing `[[custom.plugins]]`) and individual table
////   entries within the collection with index references (`custom.plugins[1]`
////   resolving to the second table in the collection).
////
//// - Key/value nodes: a leaf assignment (`key = value`). The value may be
////   a scalar value (integer, float, string, etc.), an inline table, or an
////   array.
////
//// - Inline table nodes: a table written using the inline table syntax
////   (`key = { … }`) that is part of a key/value node. Path strings may
////   extend into the inline table.
////
//// - Arrays: a value node that may represent heterogenous TOML values. Path
////   strings allow resolution to the array or elements within an array using
////   the same syntax as array of table references.
////
//// If an operation indicates that it works on a table-like path, it means that
//// it may operate on concrete tables, implicit tables, or an array of tables
//// entry.
////
//// ## Operation Values
////
//// Many operations work with `Value`s from `molt/value`, a comprehensive
//// representation of TOML values that does not preserve comments or
//// formatting.
////
//// If an operation indicates that it works with a table-like value, it means
//// that it will work with a Value representing an inline table or a concrete
//// table's values.

import gleam/option.{type Option}
import molt/error.{type MoltError}
import molt/types.{type TomlKind}
import molt/value.{type Value}

pub type Operation {
  /// Appends to an array at `path`.
  ///
  /// `path` must resolve to either a value node containing an array or an array
  /// of tables. When `path` resolves to an array of tables, the `value`
  /// provided _must_ be table-like.
  Append(path: String, value: Value)

  /// Concatenate multiple values to an array at `path`.
  ///
  /// `path` must resolve to either a value node containing an array or an array
  /// of tables. When `path` resolves to an array of tables, all entries in
  /// `values` _must_ be table-like.
  Concat(path: String, values: List(Value))

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
  EnsureExists(path: String, kind: TomlKind)

  /// Inserts a value before index `before` in an array at `path`.
  ///
  /// `path` must resolve to a value node containing an array or an array of
  /// tables. When `path` resolves to an array of tables, `value` must be
  /// table-like.
  Insert(path: String, before: Int, value: Value)

  /// Inserts a key/value pair before an existing key in the table at `path`.
  ///
  /// `path` must resolve to a concrete table, array of tables entry, or
  /// implicit table. Both `before` and `key` are literal key names (immediate
  /// children of `path`). If `before` is not found, the entry is appended.
  ///
  /// When `path` is an implicit table, the new entry is emitted as a
  /// root-level dotted key.
  InsertKey(path: String, before: String, key: String, value: Value)

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
  MergeValues(
    path: String,
    entries: List(#(String, Value)),
    on_conflict: ConflictStrategy,
  )

  /// Moves the node at `from` to `to`.
  ///
  /// `from` must resolve to an existing node of any kind except the root. `to`
  /// must not already exist, and its last segment must be a key (not an index).
  /// The node is removed from `from` and re-inserted at `to`, preserving its
  /// structure.
  Move(from: String, to: String)

  /// Moves comments from the node at `from` to the node at `to`.
  ///
  /// Both `from` and `to` must resolve to concrete nodes or the root of the
  /// document (`""`).
  MoveComments(from: String, to: String)

  /// Moves a subset of keys from the table at `from` into the table at `to`.
  ///
  /// `from` must resolve to a concrete table, implicit table, or array of
  /// tables entry. `keys` are literal key names naming the immediate children
  /// of the `from` table. Keys not present in the `from` table are ignored.
  ///
  /// If `to` does not exist or is an implicit table, a concrete table header
  /// will be created. The `on_conflict` parameter controls how collisions
  /// with existing keys in the `to` table are resolved.
  MoveKeys(
    from: String,
    to: String,
    keys: List(String),
    on_conflict: ConflictStrategy,
  )

  /// Unconditionally places `value` at `path`.
  ///
  /// If `path` already exists, it is removed before writing the `value`.
  /// Structural `Value`s (table, array of tables, etc.) are permitted.
  Place(path: String, value: Value)

  /// Removes the node at `path` from the document.
  ///
  /// If `path` resolves to an implicit table, the implicit table and _all_
  /// concrete nodes beneath it are removed.
  Remove(path: String)

  /// Renames the last segment of `path` to `to`.
  ///
  /// The last segment of `path` must be a key. `to` is a literal key name and
  /// must not already exist as a sibling.
  ///
  /// Renaming an implicit table renames all concrete descendants that reference
  /// it.
  Rename(path: String, to: String)

  /// Converts the structure at `path` between inline and block forms.
  ///
  /// `path` must resolve to a table or array of tables. The data is preserved;
  /// only the representation changes (inline table ↔ table section, array of
  /// inline tables ↔ array of tables entries).
  ///
  /// A `path` that does not reference a convertible structure is
  /// a `TypeMismatch`. Conversions that would produce invalid TOML (e.g.,
  /// inlining a table with sub-table descendants) are rejected.
  Representation(path: String, form: Form)

  /// Sets a value at `path` in the document.
  ///
  /// Creates or overwrites a key/value node. If `path` does not exist, it is
  /// created (with implicit ancestors as needed). If `path` resolves to an
  /// existing value node, the value is replaced.
  ///
  /// If `path` resolves to a structural node (section tables, array of tables,
  /// implicit tables) or `value` would render a structural node (section
  /// tables, array of tables), `Set` will return a `TypeMismatch` error.
  Set(path: String, value: Value)

  /// Sets comments on the node at `path`.
  ///
  /// `path` must resolve to a concrete node (not an implicit table) or the root
  /// of the document (`""`). Replaces any existing comments on the node with
  /// the provided `comments`.
  SetComments(path: String, comments: Comments)

  /// Transfers all keys from `from` to `to`, then removes `from`.
  ///
  /// `from` must resolve to a concrete or implicit table. `to` will be
  /// created as a concrete table if it does not exist. The `on_conflict`
  /// parameter controls how collisions with existing keys in `to` are
  /// resolved.
  Transfer(from: String, to: String, on_conflict: ConflictStrategy)

  /// Transforms a value in place via callback.
  ///
  /// `path` must resolve to a scalar, array, or inline table value node.
  /// Structural types (concrete tables, implicit tables, array of tables) are
  /// rejected with `TypeMismatch`.
  ///
  /// Transforming inline tables or arrays round-trips through `Value`, which
  /// loses internal comments and multiline formatting.
  Update(path: String, with: fn(Value) -> Result(Value, MoltError))
}

pub type Form {
  /// The table or array of tables is in a "block" form:
  ///
  /// ```toml
  /// [a]
  /// b = 1
  /// c = 2
  ///
  /// [[q]]
  /// r = 1
  ///
  /// [[q]]
  /// r = 2
  /// ```
  Block
  /// The table or array of tables is in an inline form:
  ///
  /// ```toml
  /// a = { b = 1, c = 2 }
  ///
  /// q = [{ r = 1 }, { r = 2 }]
  /// ```
  Inline
}

/// Strategy for handling key conflicts during move/merge operations.
pub type ConflictStrategy {
  /// Error if destination key already exists.
  OnConflictError
  /// Overwrite destination with source value.
  OnConflictOverwrite
  /// Skip keys that already exist in destination.
  OnConflictSkip
}

/// Comments attached to a node.
pub type Comments {
  Comments(leading: List(String), trailing: Option(String))
}
