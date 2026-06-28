//// molt/cst: low-level concrete syntax tree manipulation
////
//// The functions in this module query and manipulate concrete syntax tree
//// nodes of a TOML document.
////
//// ## `molt/cst` Functions
////
//// There are six categories of functions in the `molt/cst` interface.
////
//// - `conversion`: Conversion between the molt document to a bare CST tree
////   and back.
////
//// - `query`: Functions to query information from the CST tree nodes.
////
//// - `edit`: Functions to make edits to the CST tree. The edits produced by
////   these functions ensure local consistency but may produce a document tree
////   that is not semantically valid TOML (duplicated headers, keys that
////   conflict with a declared table, etc.).
////
//// - `comments`: Functions to edit comments on CST tree nodes.
////
//// - `builder`: Functions to build loose CST nodes for use with the `edit`
////   functions responsible for inserting or updating value nodes.
////
//// - `advanced`: Advanced functions that return an editable zipper (cursor)
////   to be used with [`greenwood/zipper`][gz]. This is more completely
////   described in the [Repairing Invalid TOML][rit] guide.
////
//// `parse_path` is uncategorized as it is a helper for translating `molt`
//// path strings (`a.b.c[3].d`) into path segments for use with `molt/cst`
//// functions.
////
//// ## Example Document
////
//// Examples in this documentation assume the following TOML document:
////
//// ```toml
//// # Project configuration
//// title = 'molt'
//// version = '1.0.0'
//// enabled = true # Do we need this?
//// max_retries = 3
//// rating = 4.5
////
//// # Inline table and inline array
//// owner = { name = \"Austin\", active = true }
//// project.tags = ['toml', \"parser\", 'gleam']
////
//// # Implicit table: `database` is never explicitly declared
//// [database.connection]
//// # Default host is localhost
//// host = 'localhost'
//// # Default port is the postgresql port
//// port = 5432
//// \"connection options\" = []
////
//// # Concrete table
//// [settings]
//// verbose = false
//// timeout = 30
////
//// [settings.debug]
//// level = 5
////
//// # Table array
//// [[plugins]]
//// name = 'formatter'
//// priority = 1
////
//// [[plugins]]
//// name = 'linter'
//// priority = 2
//// options = { strict = true, fix = false }
////
//// [[extensions]]
////
//// [app.'Microsoft Word'.options]
//// verbose = false
//// ```
////
//// All function examples are operating on the document provided as a string
//// called `config`:
////
//// ```gleam
//// import molt
//// import molt/cst
//// import molt/types.{IndexSegment, KeySegment}
////
//// use document <- result.try(molt.parse(config))
//// let example = cst.from_document(document)
//// ```
////
//// ## Concrete Node Resolution
////
//// The `molt/cst` functions target concrete container nodes in the syntax
//// tree, and advanced functions may traverse inner values.
////
//// - Concrete: implicit intermediate nodes are not reachable. In the example
////   document neither `project` nor `database` are reachable because they do
////   not exist in the syntax. Only `project.tags` and `database.connection`
////   exist as addressable nodes.
////
//// - Container nodes: the main target for `molt/cst` functions are container
////   nodes: tables (`database.connection`, `settings`), array tables
////   (`plugins`), and key/value nodes (`title`, `owner`, `project.tags`,
////   etc.).
////
//// - Inner value traversal: `molt/cst` functions can navigate into inline
////   table (`owner.name`) and inline array (`project.tags[-1]`) values owned
////   by key/value nodes.
////
//// ## Node Preservation
////
//// Modification to the CST preserves existing whitespace, comments, and
//// formatting of unaffected nodes. Comments can be added, removed, or modified
//// on any concrete node. Newly added nodes will have uniform formatting
//// applied. If a node with comments attached to it is moved to a different
//// location in the document, the comments follow that node.
////
//// ## Paths
////
//// `molt/cst` functions take paths as `List(PathSegment)`, built from
//// `KeySegment` and `IndexSegment` values or parsed from a string with
//// `parse_path`.
////
//// [gz]: https://greenwood.hexdocs.pm/greenwood/zipper.html
//// [rit]: https://molt.hexdocs.pm/invalid-toml.html

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import greenwood.{
  type Element, type Node, type Trivia, type Zipper, Bare, Node,
  NodeElement as N, Token, TokenElement as T, Trivia,
}
import greenwood/zipper
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/insert
import molt/internal/cst/query
import molt/internal/path
import molt/internal/utils
import molt/internal/validate
import molt/types.{type PathSegment, type TomlKind, IndexSegment, KeySegment}

/// Position for inserting a key/value node into a table-like container,
/// relative to other keys in the table.
///
/// Used with `insert_kv`.
pub type KeyPosition {
  /// Insert after the last key/value, before the next table header.
  ///
  /// Insertions have limited region awareness: new entries are placed _before_
  /// any subtable headers.
  KvAtEnd

  /// Insert immediately before the existing child key/value named `key`.
  ///
  /// Returns `NotFound` if `key` is not a direct child key/value of the
  /// container (no silent fall-back to append).
  BeforeKey(key: String)
}

/// Position for inserting an entry into an array of tables.
///
/// Used with `insert_array_of_tables_entry`.
pub type EntryPosition {
  /// Insert after the last entry in the specified array of tables.
  EntryAtEnd

  /// Insert before the `index`-th entry in the array of tables.
  ///
  /// The index reference supports negative indexing: `-1` means "before the
  /// last entry", `-n` means "before the first entry" and returns
  /// `IndexOutOfRange` if the resolved index exceeds the number of entries.
  BeforeIndex(index: Int)
}

/// Extracts the concrete syntax tree from the parsed molt document.
///
/// `conversion`
pub fn from_document(doc: types.Document) -> Node(TomlKind) {
  doc.tree
}

/// Converts the concrete syntax tree to a parsed TOML 1.1 document.
///
/// The tree is validated on conversion (counting any errors), so the resulting
/// `Document` has an accurate `error_count` and is ready for the `molt` logical
/// API. Inspect errors with `molt.has_errors` / `molt.document_errors`.
///
/// `conversion`
pub fn to_document(tree: Node(TomlKind)) -> types.Document {
  to_document_version(tree:, version: types.v1_1)
}

/// Converts the concrete syntax tree to a parsed TOML document using the
/// specified TOML version.
///
/// The tree is validated on conversion (counting any errors), so the resulting
/// `Document` has an accurate `error_count` and is ready for the `molt` logical
/// API. Inspect errors with `molt.has_errors` / `molt.document_errors`.
///
/// `conversion`
pub fn to_document_version(
  tree tree: Node(TomlKind),
  version version: types.TomlVersion,
) -> types.Document {
  types.Document(
    tree:,
    version:,
    index: None,
    error_count: validate.count(tree),
  )
}

/// Converts a path string into a list of path segments required by
/// `molt/cst` functions, returning a `InvalidPath` if the path syntax
/// is invalid.
///
/// The path format is fully documented in the `molt` module.
///
/// ```gleam
/// parse_path("a.b.c.d")
/// // -> [KeySegment("a"), KeySegment("b"), KeySegment("c"), KeySegment("d")]
///
/// parse_path("a.b.-1.d")
/// // -> [KeySegment("a"), KeySegment("b"), KeySegment("-1"), KeySegment("d")]
///
/// parse_path("a.b.\"with space\".d")
/// // -> [KeySegment("a"), KeySegment("b"), KeySegment("with space"), KeySegment("d")]
///
/// parse_path("a.b.\"\f\".'\\f'")
/// // -> [KeySegment("a"), KeySegment("b"), KeySegment("\f"), KeySegment("\\f")]
///
/// parse_path("a.b[-1].c")
/// // -> [KeySegment("a"), KeySegment("b"), IndexSegment(-1), KeySegment("c")]
///
/// parse_path("a.b[3].c")
/// // -> [KeySegment("a"), KeySegment("b"), IndexSegment(3), KeySegment("c")]
/// ```
pub fn parse_path(path input: String) -> Result(List(PathSegment), MoltError) {
  path.parse(input)
}

/// Retrieves a child node at the given `path` relative to `node`.
///
/// ```gleam
/// cst.get(example, [])
/// // -> the document root itself
///
/// cst.get(example, [KeySegment("rating")])
/// // -> The `rating` key/value node from root
///
/// let assert Ok(plugins2) = cst.get(example, [KeySegment("plugins"), IndexSegment(1)])
/// // -> The second `plugins` entry.
///
/// cst.get(plugins2, [KeySegment("name")])
/// // -> The `name` key/value node from the second `plugins` entry.
/// ```
///
/// `query`
pub fn get(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
) -> Result(Node(TomlKind), MoltError) {
  case segments {
    [] -> Ok(node)
    _ -> query.get(node, segments)
  }
}

/// Look up a node at path matching a predicate. Useful for disambiguating
/// duplicate keys or selecting by node kind.
///
/// ```gleam
/// assert cst.get_where(example, [KeySegment("plugins")], fn(n) {
///   list.contains(cst.list_keys(n), "options")
/// }) == cst.get(example, path: [KeySegment("plugins"), IndexSegment(-1)])
/// ```
///
/// `query`
pub fn get_where(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  where predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Node(TomlKind), MoltError) {
  case segments {
    [] ->
      case predicate(node) {
        True -> Ok(node)
        False -> Error(error.not_found_path2(segments, []))
      }
    _ -> {
      use cursor <- result.try(query.get_cursor_where(
        node:,
        path: segments,
        where: predicate,
      ))
      Ok(cursor.focus)
    }
  }
}

/// Get the key name from a key/value node.
///
/// ```gleam
/// let assert Ok(kv) = cst.get(example, [KeySegment("rating")])
/// assert Some("rating") == cst.key_name(kv)
/// ```
///
/// `query`
pub fn key_name(kv: Node(TomlKind)) -> Option(String) {
  elements.key_name(kv.children)
}

/// List key names in a table (direct children only, no dotted key merging).
///
/// `query`
pub fn list_keys(table: Node(TomlKind)) -> List(String) {
  list.filter_map(table.children, fn(el) {
    case el {
      N(n) if n.kind == types.KeyValue ->
        elements.key_name(n.children) |> option.to_result(Nil)
      _ -> Error(Nil)
    }
  })
}

/// List all explicit table or array table paths that are immediate children of
/// the provided `node` if it is a document or table node. Returns `None` if the
/// `node` is neither the root of the tree nor a table.
///
/// ```gleam
/// let assert Some([
///   ["database", "connection"],
///   ["settings"],
///   ["settings", "debug"],
///   ["plugins"],
///   ["plugins"],
///   ["extensions"],
///   ["app", "Microsoft Word", "options"],
/// ]) = cst.list_tables(example)
/// ```
///
/// `query`
pub fn list_tables(node node: Node(TomlKind)) -> Option(List(List(String))) {
  use <- bool.guard(
    node.kind != types.Root && node.kind != types.Table,
    return: None,
  )

  let tables =
    list.filter_map(node.children, fn(el) {
      case el {
        N(n) if n.kind == types.Table || n.kind == types.ArrayOfTables ->
          Ok(elements.extract_key_segments(n.children))
        _ -> Error(Nil)
      }
    })

  Some(tables)
}

/// Get the raw value text from a key/value node.
///
/// ```gleam
/// let assert Ok(kv) = cst.get(example, [KeySegment("rating")])
/// assert "4.5" == cst.value_text(kv)
/// ```
///
/// `query`
pub fn value_text(kv: Node(TomlKind)) -> String {
  elements.value_tokens(kv.children)
  |> extract_value_text()
}

/// Returns a zipper focused on the first node matching the concrete path.
///
/// ```gleam
/// cst.zipper_at(example, [KeySegment("plugins"), IndexSegment(1)])
/// // -> a zipper focused on plugins[1]
///
/// cst.zipper_at(example:, [KeySegment("database"), KeySegment("connection"), KeySegment("port")])
/// // -> a zipper focused on database.connection.port
/// ```
///
/// `advanced`
pub fn zipper_at(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
) -> Result(Zipper(TomlKind), MoltError) {
  query.get_cursor(node:, path: segments)
}

/// Returns a zipper for the given path using a predicate to
/// disambiguate duplicate keys or node kind.
///
/// ```gleam
/// cst.zipper_where(
///   example:,
///   [KeySegment("database"), KeySegment("connection"), KeySegment("port")],
///   fn(n) { cst.value_text(n) == "5432" },
/// )
///
/// // -> a zipper focused on database.connection.port
/// ```
///
/// `advanced`
pub fn zipper_where(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  where predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Zipper(TomlKind), MoltError) {
  query.get_cursor_where(node:, path: segments, where: predicate)
}

/// Delete the node at the given path. Returns the modified root.
/// Works for key/values, tables, and array of table entries.
///
/// ```gleam
/// cst.delete(example, [KeySegment("plugins"), IndexSegment(0)])
/// // -> plugins[0] (name = 'formatter') has been removed
///
/// cst.delete(example, [KeySegment("database"), KeySegment("connection")])
/// // -> All of database.connection has been removed
/// ```
///
/// `edit`
pub fn delete(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
) -> Result(Node(TomlKind), MoltError) {
  use <- bool.guard(
    segments == [],
    return: Error(error.InvalidOperation("delete", None)),
  )

  use cursor <- result.try(query.get_cursor(node:, path: segments))

  zipper.delete(cursor)
  |> option.map(zipper.unzip)
  |> option.to_result(error.InvalidOperation("delete", None))
}

/// Delete a node at path matching a predicate.
///
/// ```gleam
/// cst.delete_where(
///   example,
///   [KeySegment("database"), KeySegment("connection"), KeySegment("host")],
///   fn(n) { cst.value_text(n) == "'prod'"}
/// )
/// // -> NotFound as database.connection.host is 'localhost'
/// ```
///
/// `edit`
pub fn delete_where(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  where predicate: fn(Node(TomlKind)) -> Bool,
) -> Result(Node(TomlKind), MoltError) {
  use cursor <- result.try(query.get_cursor_where(
    node:,
    path: segments,
    where: predicate,
  ))

  zipper.delete(cursor)
  |> option.map(zipper.unzip)
  |> option.to_result(error.not_found_path2(segments, []))
}

/// Ensure a table or array of table exists at path. Creates it if missing. The
/// new declaration is placed before any existing descendant headers so that
/// parent tables always precede their children.
///
/// ```gleam
/// cst.ensure(example, path: [KeySegment("my app")], kind: types.Table)
/// // -> creates a new table header ["my app"] at the end of the document
///
/// cst.ensure(example, path: [KeySegment("database")], kind: types.Table)
/// // -> creates a new table header [database] before [database.connection]
/// ```
///
/// `edit`
pub fn ensure(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  kind kind: TomlKind,
) -> Result(Node(TomlKind), MoltError) {
  let key_path = query.collect_key_prefix(segments)
  case query.get_cursor(node:, path: segments) {
    Ok(_) -> Ok(node)
    _ ->
      case kind {
        types.Table -> Ok(insert.ensure_table(node, key_path))
        types.ArrayOfTables -> Ok(insert.ensure_array_of_tables(node, key_path))
        _ ->
          Error(error.TypeMismatch(
            path: None,
            expected: "Table or ArrayOfTables kind",
            got: utils.toml_kind(kind),
          ))
      }
  }
}

/// Inserts a table or array of tables node into the document, placing it before
/// any existing descendant headers so that parent tables always precede their
/// children.
///
/// ```gleam
/// let table = cst.build_table(path: ["database"])
/// cst.insert_table_node(example, table)
/// // -> Inserts a new table node before [database.connection]
/// ```
///
/// `edit`
pub fn insert_table_node(
  node node: Node(TomlKind),
  table table: Node(TomlKind),
) -> Result(Node(TomlKind), MoltError) {
  Ok(insert.table_ordered(
    node:,
    new_table: table,
    path: elements.extract_key_segments(table.children),
  ))
}

/// Move a node from one path to another.
///
/// ```gleam
/// cst.move(
///   example,
///   from: [KeySegment("settings"), KeySegment("timeout")],
///   to: [
///     KeySegment("database"),
///     KeySegment("connection"),
///     KeySegment("connection_timeout")
///   ],
/// )
/// // -> Moves settings.timeout to database.connection.connection_timeout
/// ```
///
/// `edit`
pub fn move(
  node node: Node(TomlKind),
  from from: List(PathSegment),
  to to: List(PathSegment),
) -> Result(Node(TomlKind), MoltError) {
  use target <- result.try(get(node:, path: from))
  use node <- result.try(delete(node:, path: from))
  case target.kind {
    types.KeyValue -> {
      let new_key = case list.last(to) {
        Ok(KeySegment(name)) -> [utils.quote_key(name)]
        _ -> query.collect_key_prefix(to)
      }
      let renamed = elements.rewrite_kv_key_in_place(kv: target, new_key:)
      insert_kv(node:, into: list_init_segments(to), kv: renamed, at: KvAtEnd)
    }
    types.Table | types.ArrayOfTables -> {
      let new_path = query.collect_key_prefix(to)
      let rewritten = builder.rewrite_header_path(table: target, new_path:)
      // Append to root since after delete the destination doesn't exist yet
      Ok(greenwood.append_child(in: node, child: N(rewritten)))
    }
    _ ->
      Error(error.TypeMismatch(
        path: None,
        expected: "key_value_node or table_node",
        got: utils.toml_kind(target.kind),
      ))
  }
}

/// Rename the last segment of the path. Works for key/values, tables, and
/// array of tables headers.
///
/// ```gleam
/// cst.rename(
///   example,
///   path: [KeySegment("plugins"), IndexSegment(1), KeySegment("name")],
///   to: "id",
/// )
/// // -> renames plugins[1].name to plugins[1].id
///
/// cst.rename(
///   example,
///   path: [KeySegment("database"), KeySegment("connection")],
///   to: "conn",
/// )
/// // -> renames [database.connection] to [database.conn]
/// ```
///
/// `edit`
pub fn rename(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  to new_name: String,
) -> Result(Node(TomlKind), MoltError) {
  use <- bool.guard(
    segments == [],
    return: Error(error.InvalidOperation("rename", None)),
  )

  use cursor <- result.try(query.get_cursor(node:, path: segments))

  case cursor.focus {
    Node(kind: types.KeyValue, children: [T(_key), ..rest], ..) as kv -> {
      let kv = Node(..kv, children: [T(utils.make_key_token(new_name)), ..rest])

      zipper.set_focus(zipper: cursor, node: kv)
      |> zipper.unzip
      |> Ok
    }

    Node(kind: types.Table, children:, ..) as table
    | Node(kind: types.ArrayOfTables, children:, ..) as table -> {
      let #(left, right) =
        list.split_while(children, fn(el) {
          case el {
            T(Token(types.RightBracket, ..)) -> False
            _ -> True
          }
        })

      case list.reverse(left) {
        [_key, ..left] -> {
          let children =
            list.reverse([T(utils.make_key_token(new_name)), ..left])
            |> list.append(right)

          let table = Node(..table, children:)

          zipper.set_focus(zipper: cursor, node: table)
          |> zipper.unzip
          |> Ok
        }
        _ ->
          Error(error.TypeMismatch(
            path: None,
            expected: "key_value or table",
            got: utils.toml_kind(cursor.focus.kind),
          ))
      }
    }
    _ ->
      Error(error.TypeMismatch(
        path: None,
        expected: "key_value or table",
        got: utils.toml_kind(cursor.focus.kind),
      ))
  }
}

/// Insert a key/value node into a table-like container resolved by the `into`
/// path segments.
///
/// The `into` target must be the document root (`[]`), a table declaration
/// `[KeySegment("x"), KeySegment("y")]`, or a specific array of tables entry
/// (`[KeySegment("a"), IndexSegment(2)]`).
///
/// Local consistency checks prevent the insertion of a key/value node with
/// a key name already present in the target table. If a key/value node is to be
/// inserted `Before` a key that does not exist, an error result will be
/// returned.
///
/// ```gleam
/// // Append, region-aware: lands before any [sub] headers.
/// insert_kv(doc, into: [KeySegment("database")], kv:, at: KvAtEnd)
///
/// // Before a named sibling key.
/// insert_kv(doc, into: [KeySegment("database")], kv:, at: BeforeKey("port"))
///
/// // Into a specific AoT entry.
/// insert_kv(doc, into: [KeySegment("a"), IndexSegment(2)], kv:, at: KvAtEnd)
/// ```
///
/// `edit`
pub fn insert_kv(
  node node: Node(TomlKind),
  into segments: List(PathSegment),
  kv kv: Node(TomlKind),
  at position: KeyPosition,
) -> Result(Node(TomlKind), MoltError) {
  // 1. kv must be a KeyValue node.
  use <- bool.guard(
    kv.kind != types.KeyValue,
    return: Error(error.TypeMismatch(
      path: None,
      expected: "key_value",
      got: utils.toml_kind(kv.kind),
    )),
  )
  // 2. Resolve the container.
  let focus_result = case segments {
    [] -> Ok(node)
    _ ->
      query.get_cursor(node:, path: segments)
      |> result.map(fn(c) { c.focus })
      |> result.replace_error(error.not_found_path(segments))
  }
  use focus <- result.try(focus_result)
  // 3. Container must be table-like.
  use <- bool.guard(
    focus.kind != types.Root
      && focus.kind != types.Table
      && focus.kind != types.ArrayOfTables,
    return: Error(error.TypeMismatch(
      path: None,
      expected: "table-like",
      got: utils.toml_kind(focus.kind),
    )),
  )
  // 4. Reject ambiguous AoT: focus is ArrayOfTables and path ended on
  //    a KeySegment (i.e. not indexed into a specific entry).
  use <- bool.guard(
    focus.kind == types.ArrayOfTables
      && {
      case list.last(segments) {
        Ok(KeySegment(_)) -> True
        _ -> False
      }
    },
    return: Error(error.InvalidOperation(
      operation: "insert_kv",
      reason: Some(
        "ambiguous array_of_tables target; specify an entry index, e.g. a.b[0]",
      ),
    )),
  )
  // 5. Collision check: key in list_keys(focus) OR focus_keys ++ [key] in list_tables(node).
  use key <- result.try(case elements.key_name(kv.children) {
    Some(k) -> Ok(k)
    None -> Ok("")
  })
  let focus_key_path = query.collect_key_prefix(segments)
  let header_key = list.append(focus_key_path, [key])
  let already_kv = list.contains(list_keys(focus), key)
  let already_header = case list_tables(node:) {
    Some(tables) -> list.contains(tables, header_key)
    None -> False
  }
  use <- bool.guard(
    already_kv || already_header,
    return: Error(error.InvalidOperation(
      operation: "insert_kv",
      reason: Some("key \"" <> key <> "\" already exists"),
    )),
  )
  // 6. For BeforeKey(k), the anchor key must exist.
  use placement <- result.try(case position {
    KvAtEnd -> Ok(insert.KvRegionEnd)
    BeforeKey(k) ->
      case list.contains(list_keys(focus), k) {
        True -> Ok(insert.BeforeKvKey(k))
        False ->
          Error(error.not_found_path(list.append(segments, [KeySegment(k)])))
      }
  })
  insert.place(node:, into: segments, new: kv, at: placement)
}

/// Insert an array of tables entry node into an existing `[[array.of.tables]]`
/// group.
///
/// The array of tables entry must be located using `into` of only `KeySegment`s
/// to find the appropriate siblings to place the table in the correct location.
///
/// ```gleam
/// let entry = cst.build_array_of_tables(["plugins"])
///
/// // Append after the last [[plugins]].
/// insert_array_of_tables_entry(
///   doc,
///   into: [KeySegment("plugins")],
///   entry:,
///   at: EntryAtEnd
/// )
///
/// // Insert before the 2nd [[a.b]] entry.
/// insert_array_of_tables_entry(
///   doc,
///   into: [KeySegment("a"), KeySegment("b")],
///   entry:,
///   at: BeforeIndex(2)
/// )
/// ```
///
/// `edit`
pub fn insert_array_of_tables_entry(
  node node: Node(TomlKind),
  into segments: List(PathSegment),
  entry entry: Node(TomlKind),
  at position: EntryPosition,
) -> Result(Node(TomlKind), MoltError) {
  // 1. `segments` must be all KeySegments.
  use <- bool.guard(
    list.any(segments, fn(seg) {
      case seg {
        IndexSegment(_) -> True
        _ -> False
      }
    }),
    return: Error(error.InvalidOperation(
      operation: "insert_array_of_tables_entry",
      reason: Some("target path must not contain an index"),
    )),
  )
  // 2. entry must be ArrayOfTables.
  use <- bool.guard(
    entry.kind != types.ArrayOfTables,
    return: Error(error.TypeMismatch(
      path: None,
      expected: "array_of_tables",
      got: utils.toml_kind(entry.kind),
    )),
  )
  // 3. entry key path must match segments keys.
  let scope_keys = query.collect_key_prefix(segments)
  let entry_keys = elements.extract_key_segments(entry.children)
  use <- bool.guard(
    entry_keys != scope_keys,
    return: Error(error.InvalidOperation(
      operation: "insert_array_of_tables_entry",
      reason: Some(
        "entry path ["
        <> string.join(entry_keys, ", ")
        <> "] does not match target segments ["
        <> string.join(scope_keys, ", ")
        <> "]",
      ),
    )),
  )
  // 4 & 5. Inspect root children for segments members; detect structural collisions.
  let family_members =
    list.filter(node.children, fn(el) {
      case el {
        greenwood.NodeElement(n) if n.kind == types.ArrayOfTables ->
          elements.extract_key_segments(n.children) == scope_keys
        _ -> False
      }
    })
  let collision_table =
    list.any(node.children, fn(el) {
      case el {
        greenwood.NodeElement(n) if n.kind == types.Table ->
          elements.extract_key_segments(n.children) == scope_keys
        _ -> False
      }
    })
  let collision_kv =
    list.any(node.children, fn(el) {
      case el {
        greenwood.NodeElement(n) if n.kind == types.KeyValue ->
          elements.key_name(n.children) == Some(string.join(scope_keys, "."))
        _ -> False
      }
    })
  use <- bool.guard(
    collision_table || collision_kv,
    return: Error(error.InvalidOperation(
      operation: "insert_array_of_tables_entry",
      reason: Some(
        "[" <> string.join(scope_keys, ".") <> "] is not an array of tables",
      ),
    )),
  )
  use <- bool.guard(
    list.is_empty(family_members),
    return: Error(error.not_found_path(segments)),
  )
  // 6. For BeforeIndex(i), validate bounds.
  let count = list.length(family_members)
  use placement <- result.try(case position {
    EntryAtEnd -> Ok(insert.FamilyScopeEnd(scope_keys))
    BeforeIndex(i) ->
      case utils.resolve_insert_position(i, count) {
        Ok(resolved) if resolved == count ->
          Ok(insert.FamilyScopeEnd(scope_keys))
        Ok(resolved) ->
          Ok(insert.BeforeFamilyIndex(family: scope_keys, index: resolved))
        Error(Nil) ->
          Error(error.IndexOutOfRange(
            path: utils.path_to_string(segments),
            index: i,
            length: count,
          ))
      }
  })
  insert.place(node:, into: [], new: entry, at: placement)
}

/// Replace the node at path with a new node.
///
/// ```gleam
/// let assert Ok(existing) =
///   cst.get(example, path: [
///     KeySegment("plugins"),
///     IndexSegment(0),
///     KeySegment("priority"),
///   ])
///
/// let assert Ok(new_kv) =
///   cst.set_kv_value(kv: existing, value: value.to_cst(value.int(10)))
/// cst.replace(
///   example,
///   path: [KeySegment("plugins"), IndexSegment(0), KeySegment("priority")],
///   new: new_kv,
/// )
/// // -> changes plugins[0].priority to 10
/// ```
///
/// `edit`
pub fn replace(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  new new: Node(TomlKind),
) -> Result(Node(TomlKind), MoltError) {
  case segments {
    [] -> Ok(new)
    _ -> {
      use cursor <- result.try(query.get_cursor(node:, path: segments))

      zipper.set_focus(zipper: cursor, node: new)
      |> zipper.unzip
      |> Ok
    }
  }
}

/// Update the node at path via a transform function.
///
/// ```gleam
/// cst.update(example,
///   path: [
///     KeySegment("database"),
///     KeySegment("connection"),
///     KeySegment("port")
///   ],
///   with: fn(kv) {
///     let assert Ok(updated) =
///       cst.set_kv_value(kv:, value: value.to_cst(value.int(9090)))
///     updated
///   }
/// )
/// // -> Updates database.connection.port to 9090
/// ```
///
/// `edit`
pub fn update(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  with transform: fn(Node(TomlKind)) -> Node(TomlKind),
) -> Result(Node(TomlKind), MoltError) {
  use cursor <- result.try(query.get_cursor(node:, path: segments))

  zipper.map_focus(zipper: cursor, with: transform)
  |> zipper.unzip
  |> Ok
}

/// Replace the value of a key/value pair node, preserving the key, surrounding
/// whitespace, and any attached comments.
///
/// The `value` is a CST element produced from a `value.Value` with
/// `value.to_cst`, so the replacement is a correctly-typed value node (integer,
/// string, array, inline table, etc.). Build it from a `value.Value` rather than
/// from raw text.
///
/// ```gleam
/// import molt/value
///
/// let assert Ok(existing) =
///   cst.get(example, path: [
///     KeySegment("plugins"),
///     IndexSegment(0),
///     KeySegment("priority"),
///   ])
///
/// let assert Ok(new_kv) =
///   cst.set_kv_value(kv: existing, value: value.to_cst(value.int(10)))
/// ```
///
/// `edit`
pub fn set_kv_value(
  kv kv: Node(TomlKind),
  value value: Element(TomlKind),
) -> Result(Node(TomlKind), MoltError) {
  case kv.kind {
    types.KeyValue ->
      Ok(
        Node(
          ..kv,
          children: replace_value_element(children: kv.children, new: value),
        ),
      )
    _ ->
      Error(error.TypeMismatch(
        path: None,
        expected: "key_value",
        got: utils.toml_kind(kv.kind),
      ))
  }
}

/// Update a node at path matching a predicate via a transform function.
///
/// ```gleam
/// cst.update_where(
///   example,
///   path: [KeySegment("database"), KeySegment("connection"), KeySegment("port")],
///   where: fn(n) { cst.value_text(n) == "9999" },
///   with: fn(n) {
///     let assert Ok(updated) =
///       cst.set_kv_value(kv: n, value: value.to_cst(value.int(9090)))
///     updated
///   },
/// )
/// // -> Returns not found because database.connection.port is 5432, not 9999.
/// ```
///
/// `edit`
pub fn update_where(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  where predicate: fn(Node(TomlKind)) -> Bool,
  with transform: fn(Node(TomlKind)) -> Node(TomlKind),
) -> Result(Node(TomlKind), MoltError) {
  use cursor <- result.try(query.get_cursor_where(
    node:,
    path: segments,
    where: predicate,
  ))

  zipper.map_focus(zipper: cursor, with: transform)
  |> zipper.unzip
  |> Ok
}

/// Get leading comments attached to the node at path.
///
/// ```gleam
/// cst.leading_comments(
///   example,
///   [KeySegment("database"), KeySegment("connection"), KeySegment("host")]
/// )
/// // -> Ok(["# Default host is localhost"])
/// ```
///
/// `comments`
pub fn leading_comments(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
) -> Result(List(String), MoltError) {
  use target <- result.try(get(node:, path: segments))
  Ok(extract_leading_comments(target))
}

/// Set leading comments on the node at path.
///
/// ```gleam
/// cst.set_leading_comments(
///   example,
///   path: [KeySegment("database"), KeySegment("connection"), KeySegment("port")],
///   comments: ["Listen port"],
/// )
/// // -> Adds "# Listen port" before database.connection.port
/// ```
///
/// `comments`
pub fn set_leading_comments(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  comments cmts: List(String),
) -> Result(Node(TomlKind), MoltError) {
  update(node:, path: segments, with: fn(target) {
    apply_leading_comments(target, cmts)
  })
}

/// Get the trailing comment on the node at path, if any.
///
/// ```gleam
/// cst.trailing_comment(example, [KeySegment("enabled")])
/// // -> Ok(Some("# Do we need this?"))
/// ```
///
/// `comments`
pub fn trailing_comment(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
) -> Result(option.Option(String), MoltError) {
  use target <- result.try(get(node:, path: segments))
  Ok(extract_trailing_comment(target))
}

/// Set or clear the trailing comment on the node at path. Pass `None` to remove
/// an existing trailing comment.
///
/// ```gleam
/// cst.set_trailing_comment(example, [KeySegment("rating")], Some("Higher!"))
/// // -> Adds "# Higher!" to rating
///
/// cst.set_trailing_comment(
///   example,
///   [KeySegment("enabled")],
///   None
/// )
/// // -> Removes the comment from enabled.
/// ```
///
/// `comments`
pub fn set_trailing_comment(
  node node: Node(TomlKind),
  path segments: List(PathSegment),
  comment comment: option.Option(String),
) -> Result(Node(TomlKind), MoltError) {
  update(node:, path: segments, with: apply_trailing_comment(_, comment))
}

/// Recursively strip all comments from the tree.
///
/// ```gleam
/// cst.strip_all_comments(example)
/// // -> Removes all leading and trailing comments from the tree
/// ```
///
/// `comments`
pub fn strip_all_comments(node node: Node(TomlKind)) -> Node(TomlKind) {
  strip_comments(node:)
}

/// Read the document-head comments: the Root node's own leading-trivia comment
/// lines, returned verbatim (with the leading `#`). These are the comments that
/// belong to the file rather than to any one statement.
///
/// `comments`
pub fn document_head_comments(tree tree: Node(TomlKind)) -> List(String) {
  extract_leading_comments(tree)
}

/// Replace the document-head comments on the Root node's leading trivia,
/// preserving a leading BOM. An empty list clears the comments (keeping the
/// BOM). The blank line that separates the head comment from the first statement
/// is added at emit time (see `emitter.ensure_head_separation`), so it tracks
/// the document's content and line-ending style rather than being baked in here.
///
/// `comments`
pub fn set_document_head_comments(
  tree tree: Node(TomlKind),
  comments comments: List(String),
) -> Node(TomlKind) {
  let #(leading, trailing) = case tree.trivia {
    Bare -> #([], [])
    Trivia(leading:, trailing:) -> #(leading, trailing)
  }
  // Keep a leading BOM (document-head trivia that must stay first); drop any
  // previous head comments / blank runs — set is replace semantics. Synthesized
  // newlines carry empty text; the emitter renders them in the document's style.
  let bom = list.take_while(leading, fn(t) { t.kind == types.Bom })
  let body =
    list.flat_map(comments, fn(text) {
      [
        Token(kind: types.Comment, text: normalize_comment(text)),
        Token(kind: types.Newline, text: ""),
      ]
    })
  Node(..tree, trivia: Trivia(leading: list.append(bom, body), trailing:))
}

/// Read the document-tail comments: the leading-trivia comment lines of the
/// `PostScript` tombstone, if the document has one (it has one exactly when
/// trivia dangles after the final statement). Returns `[]` otherwise.
///
/// `comments`
pub fn document_tail_comments(tree tree: Node(TomlKind)) -> List(String) {
  case find_postscript(tree) {
    Some(ps) -> extract_leading_comments(ps)
    None -> []
  }
}

/// Replace the document-tail comments. A non-empty list materializes (or
/// updates) the `PostScript` tombstone as the document's last child; an empty
/// list drops the tombstone entirely so no empty node lingers.
///
/// `comments`
pub fn set_document_tail_comments(
  tree tree: Node(TomlKind),
  comments comments: List(String),
) -> Node(TomlKind) {
  let without =
    list.filter(tree.children, fn(el) {
      case el {
        N(n) if n.kind == types.PostScript -> False
        _ -> True
      }
    })
  case comments {
    [] -> Node(..tree, children: without)
    _ -> {
      // A set always opens the tombstone with a leading newline, so the tail
      // comments are separated from the preceding content by a blank line (the
      // content's own terminating newline + this one). A *parsed* tail keeps
      // whatever spacing was in the source; this separator is set-only.
      // Synthesized newlines carry empty text; the emitter renders them in the
      // document's line-ending style.
      let body =
        list.flat_map(comments, fn(text) {
          [
            Token(kind: types.Comment, text: normalize_comment(text)),
            Token(kind: types.Newline, text: ""),
          ]
        })
      let leading = [Token(kind: types.Newline, text: ""), ..body]
      let ps =
        Node(
          kind: types.PostScript,
          children: [],
          trivia: Trivia(leading:, trailing: []),
        )
      Node(..tree, children: list.append(without, [N(ps)]))
    }
  }
}

fn find_postscript(tree: Node(TomlKind)) -> Option(Node(TomlKind)) {
  list.find_map(tree.children, fn(el) {
    case el {
      N(n) if n.kind == types.PostScript -> Ok(n)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Build an empty array of tables header node (`[[path.to.table]]\n`).
///
/// ```gleam
/// cst.build_array_of_tables(["plugins"])  // -> [[plugins]]
/// cst.build_array_of_tables(["app", "hooks"])  // -> [[app.hooks]]
/// ```
///
/// `builder`
pub fn build_array_of_tables(path path: List(String)) -> Node(TomlKind) {
  // The internal builder bakes in a leading-newline separator for internal
  // ordered inserts; a header handed to a caller must be bare (`[[path]]`), or
  // placing it first in a document emits a spurious blank line.
  builder.build_empty_array_of_tables(path)
  |> builder.drop_leading_newlines
}

/// Build comment trivia for attaching to a node via `greenwood.set_trivia` or
/// similar. Leading comments appear on lines before the node; the trailing
/// comment appears on the same line after the value.
///
/// ```gleam
/// cst.build_comment_trivia(
///   leading: ["# Section start"],
///   trailing: Some("inline note"),
/// )
/// ```
///
/// `builder`
pub fn build_comment_trivia(
  leading leading: List(String),
  trailing trailing: option.Option(String),
) -> Trivia(TomlKind) {
  let leading =
    list.flat_map(leading, fn(text) {
      [
        Token(kind: types.Comment, text: normalize_comment(text)),
        Token(kind: types.Newline, text: ""),
      ]
    })
  let trailing = case trailing {
    None -> []
    Some(text) -> [
      Token(kind: types.Whitespace, text: " "),
      Token(kind: types.Comment, text: normalize_comment(text)),
    ]
  }
  Trivia(leading:, trailing:)
}

/// Build a key/value node for use inside inline tables (no trailing newline).
///
/// `builder`
pub fn build_inline_kv(
  key key: String,
  value value: Element(TomlKind),
) -> Node(TomlKind) {
  builder.build_inline_kv(key: utils.quote_key(key), value:)
}

/// Build a key/value node with standard formatting (`key = value\n`).
///
/// The key will be quoted if necessary. The value should be produced via
/// `value.to_cst`.
///
/// ```gleam
/// cst.build_kv(key: "host", value: value.to_cst(value.string("localhost")))
/// ```
///
/// `builder`
pub fn build_kv(
  key key: String,
  value value: Element(TomlKind),
) -> Node(TomlKind) {
  builder.build_kv_node(key: utils.quote_key(key), value:)
}

/// Build an empty table header node (`[path.to.table]\n`).
///
/// ```gleam
/// cst.build_table(["settings"])  // -> [settings]
/// cst.build_table(["database", "connection"])  // -> [database.connection]
/// ```
///
/// `builder`
pub fn build_table(path path: List(String)) -> Node(TomlKind) {
  // See `build_array_of_tables`: return a bare `[path]` header, not the
  // internal separator-prefixed node.
  builder.build_empty_table(path)
  |> builder.drop_leading_newlines
}

fn apply_leading_comments(
  node: Node(TomlKind),
  comments: List(String),
) -> Node(TomlKind) {
  let comment_tokens =
    list.flat_map(comments, fn(text) {
      [
        Token(kind: types.Comment, text: normalize_comment(text)),
        Token(kind: types.Newline, text: ""),
      ]
    })
  // Keep any blank-line / whitespace trivia above the comments, so setting a
  // comment never collapses the spacing above the node (e.g. the section break
  // before a table header).
  let prefix = case node.trivia {
    Bare -> []
    Trivia(leading:, ..) ->
      list.take_while(leading, fn(t) {
        t.kind == types.Newline || t.kind == types.Whitespace
      })
  }
  let leading = list.append(prefix, comment_tokens)
  let new_trivia = case node.trivia {
    Bare -> Trivia(leading:, trailing: [])
    Trivia(trailing:, ..) -> Trivia(leading:, trailing:)
  }
  Node(..node, trivia: new_trivia)
}

fn normalize_comment(text: String) -> String {
  use <- bool.guard(string.starts_with(text, "#"), return: text)
  "# " <> text
}

fn extract_value_text(children: List(Element(TomlKind))) -> String {
  children
  |> list.filter_map(fn(el) {
    case el {
      T(Token(kind: types.Whitespace, ..)) -> Error(Nil)
      T(Token(kind: types.Newline, ..)) -> Error(Nil)
      T(Token(kind: types.Comment, ..)) -> Error(Nil)
      T(Token(kind: types.BasicString, text:)) -> Ok("\"" <> text <> "\"")
      T(Token(kind: types.MultilineBasicString, text:)) ->
        Ok("\"\"\"" <> text <> "\"\"\"")
      T(Token(kind: types.MultilineBasicStringNl, text:)) ->
        Ok("\"\"\"\n" <> text <> "\"\"\"")
      T(Token(kind: types.LiteralString, text:)) -> Ok("'" <> text <> "'")
      T(Token(kind: types.MultilineLiteralString, text:)) ->
        Ok("'''" <> text <> "'''")
      T(Token(kind: types.MultilineLiteralStringNl, text:)) ->
        Ok("'''\n" <> text <> "'''")
      T(t) -> Ok(t.text)
      N(n) -> Ok(emit_node_text(n))
    }
  })
  |> string.concat
  |> string.trim
}

fn emit_node_text(node: Node(TomlKind)) -> String {
  node.children
  |> list.map(fn(el) {
    case el {
      T(Token(kind: types.BasicString, text:)) -> "\"" <> text <> "\""
      T(Token(kind: types.MultilineBasicString, text:)) ->
        "\"\"\"" <> text <> "\"\"\""
      T(Token(kind: types.MultilineBasicStringNl, text:)) ->
        "\"\"\"\n" <> text <> "\"\"\""
      T(Token(kind: types.LiteralString, text:)) -> "'" <> text <> "'"
      T(Token(kind: types.MultilineLiteralString, text:)) ->
        "'''" <> text <> "'''"
      T(Token(kind: types.MultilineLiteralStringNl, text:)) ->
        "'''\n" <> text <> "'''"
      T(Token(kind: types.Equals, ..)) -> "="
      T(Token(kind: types.Dot, ..)) -> "."
      T(Token(kind: types.Comma, ..)) -> ","
      T(Token(kind: types.LeftBracket, ..)) -> "["
      T(Token(kind: types.RightBracket, ..)) -> "]"
      T(Token(kind: types.LeftBrace, ..)) -> "{"
      T(Token(kind: types.RightBrace, ..)) -> "}"
      T(t) -> t.text
      N(n) -> emit_node_text(n)
    }
  })
  |> string.concat
}

fn replace_value_element(
  children children: List(Element(TomlKind)),
  new new_value: Element(TomlKind),
) -> List(Element(TomlKind)) {
  case elements.split_at_equals(children) {
    #(prefix, [eq, ..after_eq]) -> {
      let #(pre_ws, value_and_rest) = elements.split_leading_ws(after_eq)
      let #(_old_value, trailing) = elements.split_before_trivia(value_and_rest)
      list.flatten([prefix, [eq], pre_ws, [new_value], trailing])
    }
    // No Equals: degenerate KV, leave the children alone.
    #(_, []) -> children
  }
}

fn list_init_segments(l: List(PathSegment)) -> List(PathSegment) {
  case l {
    [] | [_] -> []
    _ -> list.take(l, list.length(l) - 1)
  }
}

/// Strip all comments from the document
fn strip_comments(node node: Node(TomlKind)) -> Node(TomlKind) {
  let trivia = case node.trivia {
    Bare -> Bare
    Trivia(leading:, trailing:) ->
      Trivia(
        leading: list.filter(leading, fn(t) { t.kind != types.Comment }),
        trailing: list.filter(trailing, fn(t) { t.kind != types.Comment }),
      )
  }
  let children =
    list.filter_map(node.children, fn(el) {
      case el {
        T(Token(kind: types.Comment, ..)) -> Error(Nil)
        N(n) -> Ok(N(strip_comments(node: n)))
        _ -> Ok(el)
      }
    })
  Node(..node, children:, trivia:)
}

fn extract_leading_comments(node: Node(TomlKind)) -> List(String) {
  case node.trivia {
    Bare -> []
    Trivia(leading:, ..) ->
      list.filter_map(leading, fn(t) {
        case t.kind {
          types.Comment -> Ok(t.text)
          _ -> Error(Nil)
        }
      })
  }
}

fn extract_trailing_comment(node: Node(TomlKind)) -> option.Option(String) {
  case node.trivia {
    Bare -> None
    Trivia(trailing:, ..) ->
      list.find_map(trailing, fn(t) {
        case t.kind {
          types.Comment -> Ok(t.text)
          _ -> Error(Nil)
        }
      })
      |> option.from_result
  }
}

fn apply_trailing_comment(
  node: Node(TomlKind),
  comment: option.Option(String),
) -> Node(TomlKind) {
  let trailing = case comment {
    None -> []
    Some(text) -> [
      Token(kind: types.Whitespace, text: " "),
      Token(kind: types.Comment, text: normalize_comment(text)),
    ]
  }
  let new_trivia = case node.trivia {
    Bare -> Trivia(leading: [], trailing:)
    Trivia(leading:, ..) -> Trivia(leading:, trailing:)
  }
  Node(..node, trivia: new_trivia)
}
