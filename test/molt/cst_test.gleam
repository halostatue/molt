//// Tests for molt/cst

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import greenwood.{
  type Node, Node, NodeElement as N, Token, TokenElement as T, Trivia,
}
import greenwood/zipper
import molt
import molt/cst
import molt/error.{
  IndexOutOfRange, InvalidOperation, InvalidPath, NotFound, TypeMismatch,
}
import molt/types.{type PathSegment, type TomlKind, IndexSegment, KeySegment}
import molt/value
import test_documents as docs

pub fn to_document_test() {
  let node = cst_parse(docs.config)
  let doc = cst.to_document(node)
  // Conversion validates in count mode: a valid tree yields error_count 0.
  assert 0 == doc.error_count
  assert types.v1_1 == doc.version
  assert node == doc.tree
  assert None == doc.index
}

pub fn to_document_version_test() {
  let node = cst_parse(docs.config)
  let doc = cst.to_document_version(node, version: molt.v1_0)
  assert 0 == doc.error_count
  assert types.v1_0 == doc.version
  assert node == doc.tree
  assert None == doc.index
}

pub fn get_from_root_test() {
  let node = cst_parse(docs.config)

  let assert Ok(Node(kind: types.Root, ..) as root) = cst.get(node:, path: [])
  assert root == node

  let assert Ok(Node(kind: types.KeyValue, ..)) =
    cst.get(node:, path: p(["title"]))

  let assert Ok(Node(
    kind: types.KeyValue,
    children: [T(Token(kind: types.BareKey, text: "rating")), ..],
    ..,
  )) = cst.get(node:, path: p(["rating"]))

  let assert Error(NotFound(path: "nope", at: "")) =
    cst.get(node:, path: p(["nope"]))
}

pub fn get_from_child_node_test() {
  let node = cst_parse(docs.config)
  let assert Ok(settings) = cst.get(node:, path: p(["settings"]))
  let assert Ok(Node(kind: types.KeyValue, ..)) =
    cst.get(settings, path: p(["verbose"]))
  let assert Ok(Node(kind: types.KeyValue, ..)) =
    cst.get(node:, path: p(["settings", "verbose"]))

  // cst.get is not a logical lookup, so `debug` is root → settings.debug, not
  // root → settings → debug
  let assert Error(NotFound(path: "debug", at: "")) =
    cst.get(settings, path: p(["debug"]))
}

pub fn get_indexed_test() {
  let node = cst_parse(docs.config)
  let assert Ok(Node(kind: types.ArrayOfTables, ..)) =
    cst.get(node:, path: p(["plugins"]))

  let assert Ok(
    Node(
      kind: types.ArrayOfTables,
      children: [_, _, T(Token(kind: types.BareKey, text: "plugins")), ..],
      ..,
    ) as plugins2,
  ) = cst.get(node:, path: [KeySegment("plugins"), IndexSegment(1)])

  // Getting a key from a sub-node (not the root) works
  let assert Ok(Node(
    kind: types.KeyValue,
    children: [T(Token(kind: types.BareKey, text: "name")), ..],
    ..,
  )) = cst.get(plugins2, path: p(["name"]))

  let assert Ok(Node(kind: types.KeyValue, ..)) =
    cst.get(node:, path: [
      KeySegment("plugins"),
      IndexSegment(1),
      KeySegment("priority"),
    ])
}

pub fn find_key_test() {
  let node = cst_parse(docs.config)
  let assert Ok(kv) =
    cst.get(node:, path: p(["database", "connection", "host"]))
  let assert Some("host") = cst.key_name(kv)
  assert "'localhost'" == cst.value_text(kv)
}

pub fn list_tables_test() {
  let node = cst_parse(docs.config)
  let assert Some([
    ["database", "connection"],
    ["settings"],
    ["settings", "debug"],
    ["plugins"],
    ["plugins"],
    ["extensions"],
    ["app", "Microsoft Word", "options"],
  ]) = cst.list_tables(node:)
}

pub fn list_keys_test() {
  let node = cst_parse(docs.config)
  let assert Ok(table) = cst.get(node:, path: p(["database", "connection"]))
  assert ["host", "port", "connection options"] == cst.list_keys(table)
}

pub fn update_value_test() {
  let node = cst_parse(docs.config)
  let assert Ok(kv) =
    cst.get(node:, path: p(["database", "connection", "port"]))
  let assert Ok(new_kv) =
    cst.set_kv_value(kv:, value: value.to_cst(value.int(9090)))
  let assert Ok(node2) =
    cst.replace(node:, path: p(["database", "connection", "port"]), new: new_kv)
  let doc = cst_to_string(node2)
  assert string.contains(doc, "port = 9090")
}

pub fn delete_key_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.delete(node:, path: p(["database", "connection", "host"]))
  let result = cst_to_string(node2)
  assert False == string.contains(result, "host")
  assert string.contains(result, "port = 5432")
}

pub fn delete_table_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) = cst.delete(node:, path: p(["database", "connection"]))
  let doc = cst_to_string(node2)
  assert False == string.contains(doc, "[database.connection]")
  assert string.contains(doc, "[settings.debug]")
}

pub fn get_key_comments_test() {
  let node = cst_parse(docs.config)

  let assert Ok(["# Default host is localhost"]) =
    cst.leading_comments(node:, path: p(["database", "connection", "host"]))
}

pub fn set_key_comments_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_leading_comments(
      node:,
      path: p(["database", "connection", "port"]),
      comments: ["Listen port"],
    )
  let doc = cst_to_string(node2)

  assert string.contains(doc, "# Listen port")
}

pub fn strip_comments_test() {
  let node = cst_parse(docs.config)

  let doc = cst.strip_all_comments(node:) |> cst_to_string
  assert False == string.contains(doc, "#")
}

pub fn error_table_not_found_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "nope", ..)) =
    cst.delete(node:, path: p(["nope"]))
}

pub fn error_key_not_found_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "server.nope", at: "")) =
    cst.get(node:, path: p(["server", "nope"]))
}

pub fn get_table_comments_test() {
  let node = cst_parse(docs.config)
  let assert Ok(["# Implicit table: `database` is never explicitly declared"]) =
    cst.leading_comments(node:, path: p(["database", "connection"]))
}

pub fn get_table_comments_none_test() {
  let node = cst_parse(docs.config)
  let assert Ok([]) =
    cst.leading_comments(node:, path: p(["settings", "debug"]))
}

pub fn get_table_comments_not_found_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "nope", ..)) =
    cst.leading_comments(node:, path: p(["nope"]))
}

pub fn set_table_comments_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_leading_comments(
      node:,
      path: p(["database", "connection", "host"]),
      comments: [
        "Main server",
      ],
    )
  let doc = cst_to_string(node2)
  assert string.contains(doc, "# Main server")
}

pub fn set_table_comments_not_found_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "nope", ..)) =
    cst.set_leading_comments(node:, path: p(["nope"]), comments: ["x"])
}

pub fn strip_table_comments_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_leading_comments(
      node:,
      path: p(["database", "connection"]),
      comments: [],
    )
  let assert Ok(node3) =
    cst.set_leading_comments(
      node: node2,
      path: p(["database", "connection", "host"]),
      comments: [],
    )
  let doc = cst_to_string(node3)
  assert False == string.contains(doc, "# Implicit table:")
  assert False == string.contains(doc, "# Default host is localhost")
  assert string.contains(
    doc,
    "host = 'localhost'\n# Default port is the postgresql port\nport = 5432",
  )
}

pub fn strip_key_comments_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_leading_comments(
      node:,
      path: p(["database", "connection", "port"]),
      comments: [],
    )
  let doc = cst_to_string(node2)
  assert False == string.contains(doc, "Default port")
  assert string.contains(doc, "Default host")
}

pub fn strip_key_comments_key_not_found_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(
    path: "database.connection.nope",
    at: "database.connection",
  )) =
    cst.set_leading_comments(
      node:,
      path: p(["database", "connection", "nope"]),
      comments: [],
    )
}

pub fn get_where_kv_match_test() {
  let node = cst_parse(docs.config)
  let assert Ok(kv) =
    cst.get_where(
      node:,
      path: p(["database", "connection", "port"]),
      where: fn(n) { cst.value_text(n) == "5432" },
    )
  let assert Some("port") = cst.key_name(kv)
}

pub fn key_name_value_text_test() {
  let example = cst_parse(docs.config)
  let assert Ok(kv) = cst.get(example, [KeySegment("rating")])
  assert Some("rating") == cst.key_name(kv)
  assert "4.5" == cst.value_text(kv)
}

pub fn get_where_kv_no_match_test() {
  let node = cst_parse(docs.config)

  let assert Error(NotFound(
    path: "database.connection.port",
    at: "database.connection",
  )) =
    cst.get_where(
      node:,
      path: p(["database", "connection", "port"]),
      where: fn(n) { cst.value_text(n) == "9999" },
    )
}

pub fn get_where_table_match_test() {
  let node = cst_parse(docs.config)
  let assert Ok(Node(kind: types.ArrayOfTables, ..)) =
    cst.get_where(node:, path: p(["plugins"]), where: fn(n) {
      list.contains(cst.list_keys(n), "options")
    })

  assert cst.get_where(node:, path: p(["plugins"]), where: fn(n) {
      list.contains(cst.list_keys(n), "options")
    })
    == cst.get(node:, path: [KeySegment("plugins"), IndexSegment(-1)])
}

pub fn get_where_table_no_match_test() {
  let node = cst_parse(docs.config)

  let assert Error(NotFound(path: "plugins", at: "")) =
    cst.get_where(node:, path: p(["plugins"]), where: fn(n) {
      list.contains(cst.list_keys(n), "nope")
    })
}

pub fn get_where_empty_path_match_test() {
  let node = cst_parse(docs.config)

  let assert Ok(Node(kind: types.Root, ..)) =
    cst.get_where(node:, path: [], where: fn(n) { n.kind == types.Root })
}

pub fn get_where_empty_path_no_match_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "", at: "")) =
    cst.get_where(node:, path: [], where: fn(_) { False })
}

pub fn update_where_match_test() {
  let node = cst_parse(docs.config)

  let assert Ok(node2) =
    cst.update_where(
      node:,
      path: p(["database", "connection", "port"]),
      where: fn(n) { cst.value_text(n) == "5432" },
      with: fn(n) {
        let assert Ok(updated) =
          cst.set_kv_value(kv: n, value: value.to_cst(value.int(9090)))
        updated
      },
    )
  let doc = cst_to_string(node2)
  assert string.contains(doc, "port = 9090")
}

pub fn update_where_no_match_test() {
  let node = cst_parse(docs.config)

  let assert Error(NotFound(
    path: "database.connection.port",
    at: "database.connection",
  )) =
    cst.update_where(
      node:,
      path: p(["database", "connection", "port"]),
      where: fn(n) { cst.value_text(n) == "9999" },
      with: fn(n) {
        let assert Ok(updated) =
          cst.set_kv_value(kv: n, value: value.to_cst(value.int(9090)))
        updated
      },
    )
}

pub fn delete_where_match_test() {
  let node = cst_parse(docs.config)

  let assert Ok(node2) =
    cst.delete_where(
      node:,
      path: p(["database", "connection", "host"]),
      where: fn(n) { cst.value_text(n) == "'localhost'" },
    )
  let doc = cst_to_string(node2)
  assert False == string.contains(doc, "host")
  assert string.contains(doc, "port = 5432")
}

pub fn delete_where_no_match_test() {
  let node = cst_parse(docs.config)

  let assert Error(NotFound(path: "database.port", at: "")) =
    cst.delete_where(node:, path: p(["database", "port"]), where: fn(_) {
      False
    })
}

pub fn get_where_duplicate_keys_test() {
  // Invalid TOML but parsable: two identical keys
  let node = cst_parse("a = 1\na = 2\n")

  // Should find the one with value "2"
  let assert Ok(kv) =
    cst.get_where(node:, path: p(["a"]), where: fn(n) {
      cst.value_text(n) == "2"
    })
  let assert "2" = cst.value_text(kv)
}

pub fn delete_where_duplicate_keys_test() {
  // Invalid TOML but parsable: two identical keys
  let node = cst_parse("a = 1\na = 2\n")

  // Delete only the one with value "2"
  let assert Ok(node2) =
    cst.delete_where(node:, path: p(["a"]), where: fn(n) {
      cst.value_text(n) == "2"
    })
  let doc = cst_to_string(node2)
  assert string.contains(doc, "a = 1")
  assert False == string.contains(doc, "a = 2")
}

pub fn update_where_duplicate_keys_test() {
  // Invalid TOML but parsable: two identical keys
  let node = cst_parse("a = 1\na = 2\n")

  // Update only the one with value "1"
  let assert Ok(node2) =
    cst.update_where(
      node:,
      path: [KeySegment("a")],
      where: fn(n) { cst.value_text(n) == "1" },
      with: fn(n) {
        let assert Ok(updated) =
          cst.set_kv_value(kv: n, value: value.to_cst(value.int(99)))
        updated
      },
    )
  let doc = cst_to_string(node2)
  assert string.contains(doc, "a = 99")
  assert string.contains(doc, "a = 2")
}

pub fn get_quoted_key_test() {
  let node = cst_parse(docs.config)

  let assert Ok(kv) =
    cst.get(node:, path: p(["database", "connection", "connection options"]))
  let assert Some("connection options") = cst.key_name(kv)
  let assert "[]" = cst.value_text(kv)
}

pub fn get_quoted_table_path_test() {
  let node = cst_parse(docs.config)

  let assert Ok(kv) =
    cst.get(node:, path: p(["app", "Microsoft Word", "options", "verbose"]))
  let assert Some("verbose") = cst.key_name(kv)
}

pub fn rename_to_quoted_key_test() {
  let node = cst_parse(docs.config)

  let assert Ok(node2) =
    cst.rename(
      node:,
      path: p(["database", "connection", "host"]),
      to: "host name",
    )
  let doc = cst_to_string(node2)
  assert string.contains(doc, "\"host name\" = 'localhost'")
}

pub fn delete_quoted_key_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.delete(node:, path: p(["database", "connection", "host"]))
  let doc = cst_to_string(node2)
  // Removes the comment
  assert False == string.contains(doc, "# Default host is localhost")
  // along with the node
  assert False == string.contains(doc, "host = 'localhost'")
  assert string.contains(doc, "port = 5432")
}

pub fn insert_table_node_test() {
  let node = cst_parse(docs.config)
  let table = cst.build_table(path: ["settings", "checklist"])
  let assert Ok(node2) = cst.insert_table_node(node:, table:)
  let doc = cst_to_string(node2)
  // Grouped with its parent scope — placed right after the existing
  // [settings.debug] sub-table, not dumped at the end of the document.
  assert string.contains(
    doc,
    "[settings.debug]\nlevel = 5\n\n[settings.checklist]\n",
  )
}

pub fn insert_kv_append_to_table_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.insert_kv(
      node:,
      into: p(["database", "connection"]),
      kv: build_kv("ssl"),
      at: cst.KvAtEnd,
    )
  let assert Ok(table) =
    cst.get(node: node2, path: p(["database", "connection"]))
  assert ["host", "port", "connection options", "ssl"] == cst.list_keys(table)
}

pub fn insert_kv_before_key_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.insert_kv(
      node:,
      into: p(["database", "connection"]),
      kv: build_kv("ssl"),
      at: cst.BeforeKey("port"),
    )
  let assert Ok(table) =
    cst.get(node: node2, path: p(["database", "connection"]))
  assert ["host", "ssl", "port", "connection options"] == cst.list_keys(table)
}

pub fn insert_kv_into_aot_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.insert_kv(
      node:,
      into: [KeySegment("plugins"), IndexSegment(1)],
      kv: build_kv("enabled"),
      at: cst.KvAtEnd,
    )
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(1)])
  assert list.contains(cst.list_keys(entry), "enabled")
}

pub fn insert_kv_append_to_root_respects_region_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.insert_kv(node:, into: [], kv: build_kv("debug"), at: cst.KvAtEnd)
  let out = cst_to_string(node2)
  assert idx(out, "debug = true") >= 0
  assert idx(out, "debug = true") < idx(out, "[database.connection]")
}

pub fn insert_kv_before_missing_key_errors_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(
    path: "database.connection.nonexistent",
    at: "database.connection.nonexistent",
  )) =
    cst.insert_kv(
      node:,
      into: p(["database", "connection"]),
      kv: build_kv("ssl"),
      at: cst.BeforeKey("nonexistent"),
    )
}

pub fn insert_kv_target_not_found_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "nope", at: "nope")) =
    cst.insert_kv(
      node:,
      into: p(["nope"]),
      kv: build_kv("ssl"),
      at: cst.KvAtEnd,
    )
}

pub fn insert_kv_target_not_table_like_test() {
  let node = cst_parse(docs.config)
  let assert Error(TypeMismatch(
    path: None,
    expected: "table-like",
    got: "key_value",
  )) =
    cst.insert_kv(
      node:,
      into: p(["settings", "verbose"]),
      kv: build_kv("ssl"),
      at: cst.KvAtEnd,
    )
}

pub fn insert_kv_value_not_keyvalue_test() {
  let node = cst_parse(docs.config)
  let assert Error(TypeMismatch(path: None, expected: "key_value", got: "table")) =
    cst.insert_kv(
      node:,
      into: p(["settings"]),
      kv: cst.build_table(["settings"]),
      at: cst.KvAtEnd,
    )
}

pub fn insert_kv_ambiguous_family_test() {
  let node = cst_parse(docs.config)
  let assert Error(InvalidOperation(operation: "insert_kv", ..)) =
    cst.insert_kv(
      node:,
      into: p(["plugins"]),
      kv: build_kv("ssl"),
      at: cst.KvAtEnd,
    )
}

pub fn insert_kv_duplicate_key_append_test() {
  let node = cst_parse("[a]\nfoo = \"baz\"\n")
  let assert Error(InvalidOperation(operation: "insert_kv", ..)) =
    cst.insert_kv(node:, into: p(["a"]), kv: build_kv("foo"), at: cst.KvAtEnd)
}

pub fn insert_kv_duplicate_key_before_test() {
  let node = cst_parse("[a]\nfoo = \"baz\"\nbar = 1\n")
  let assert Error(InvalidOperation(operation: "insert_kv", ..)) =
    cst.insert_kv(
      node:,
      into: p(["a"]),
      kv: build_kv("foo"),
      at: cst.BeforeKey("bar"),
    )
}

pub fn insert_kv_structural_collision_test() {
  let node = cst_parse(docs.config)
  let assert Error(InvalidOperation(operation: "insert_kv", ..)) =
    cst.insert_kv(
      node:,
      into: p(["settings"]),
      kv: build_kv("debug"),
      at: cst.KvAtEnd,
    )
}

pub fn insert_aot_entry_at_end_scope_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["plugins"]),
      entry: marked_entry(["plugins"], "marker"),
      at: cst.EntryAtEnd,
    )
  let out = cst_to_string(node2)
  assert idx(out, "marker = true") > idx(out, "name = 'linter'")
  assert idx(out, "marker = true") < idx(out, "[[extensions]]")
}

pub fn insert_aot_entry_at_end_past_subtable_test() {
  let node = cst_parse(aot_sub)
  let assert Ok(node2) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["a", "b"]),
      entry: marked_entry(["a", "b"], "marker"),
      at: cst.EntryAtEnd,
    )
  let out = cst_to_string(node2)
  assert idx(out, "marker = true") > idx(out, "z = 3")
  assert idx(out, "marker = true") < idx(out, "[c]")
}

pub fn insert_aot_entry_before_index_test() {
  let node = cst_parse(docs.config)
  let assert Ok(pos) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["plugins"]),
      entry: cst.build_array_of_tables(["plugins"]),
      at: cst.BeforeIndex(1),
    )
  let assert Ok(neg) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["plugins"]),
      entry: cst.build_array_of_tables(["plugins"]),
      at: cst.BeforeIndex(-1),
    )
  let assert Ok(pos1) =
    cst.get(node: pos, path: [KeySegment("plugins"), IndexSegment(1)])
  let assert Ok(neg1) =
    cst.get(node: neg, path: [KeySegment("plugins"), IndexSegment(1)])
  let assert Ok(pos2) =
    cst.get(node: pos, path: [KeySegment("plugins"), IndexSegment(2)])
  assert [] == cst.list_keys(pos1)
  assert [] == cst.list_keys(neg1)
  assert ["name", "priority", "options"] == cst.list_keys(pos2)
}

pub fn insert_aot_entry_out_of_range_test() {
  let node = cst_parse(docs.config)
  let assert Error(IndexOutOfRange(path: "plugins", index: 5, length: 2)) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["plugins"]),
      entry: cst.build_array_of_tables(["plugins"]),
      at: cst.BeforeIndex(5),
    )
}

pub fn insert_aot_entry_family_with_index_test() {
  let node = cst_parse(docs.config)
  let assert Error(InvalidOperation(
    operation: "insert_array_of_tables_entry",
    reason: Some("target path must not contain an index"),
  )) =
    cst.insert_array_of_tables_entry(
      node:,
      into: [KeySegment("plugins"), IndexSegment(0)],
      entry: cst.build_array_of_tables(["plugins"]),
      at: cst.EntryAtEnd,
    )
}

pub fn insert_aot_entry_value_not_aot_test() {
  let node = cst_parse(docs.config)
  let assert Error(TypeMismatch(
    path: None,
    expected: "array_of_tables",
    got: "key_value",
  )) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["plugins"]),
      entry: build_kv("ssl"),
      at: cst.EntryAtEnd,
    )
}

pub fn insert_aot_entry_path_mismatch_test() {
  let node = cst_parse(docs.config)
  let assert Error(InvalidOperation(
    operation: "insert_array_of_tables_entry",
    reason: Some("entry path [other] does not match target segments [plugins]"),
  )) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["plugins"]),
      entry: cst.build_array_of_tables(["other"]),
      at: cst.EntryAtEnd,
    )
}

pub fn insert_aot_entry_family_missing_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "nope", at: "nope")) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["nope"]),
      entry: cst.build_array_of_tables(["nope"]),
      at: cst.EntryAtEnd,
    )
}

pub fn insert_aot_entry_target_is_table_test() {
  let node = cst_parse(docs.config)
  let assert Error(InvalidOperation(
    operation: "insert_array_of_tables_entry",
    reason: Some("[settings] is not an array of tables"),
  )) =
    cst.insert_array_of_tables_entry(
      node:,
      into: p(["settings"]),
      entry: cst.build_array_of_tables(["settings"]),
      at: cst.EntryAtEnd,
    )
}

pub fn ensure_quoted_table_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.ensure(node:, path: [KeySegment("my app")], kind: types.Table)
  let doc = cst_to_string(node2)
  assert string.contains(doc, "[\"my app\"]")
}

pub fn move_key_between_tables_test() {
  let node = cst_parse(docs.config)
  let assert Ok(updated) =
    cst.move(
      node:,
      from: p(["settings", "timeout"]),
      to: p(["database", "connection", "tmout"]),
    )
  let doc = cst_to_string(updated)

  let node2 = cst_parse(doc)
  let assert Ok(Node(kind: types.KeyValue, ..)) =
    cst.get(node: node2, path: p(["database", "connection", "tmout"]))
  let assert Ok(source) = cst.get(node: node2, path: p(["settings"]))
  assert cst.list_keys(source) == ["verbose"]
}

pub fn update_test() {
  let node = cst_parse(docs.config)

  let assert Ok(node2) =
    cst.update(node:, path: p(["database", "connection", "port"]), with: fn(kv) {
      let assert Ok(updated) =
        cst.set_kv_value(kv:, value: value.to_cst(value.int(9090)))
      updated
    })
  let doc = cst_to_string(node2)
  assert string.contains(doc, "port = 9090")
}

pub fn update_not_found_test() {
  let node = cst_parse(docs.config)

  let assert Error(NotFound(path: "database.config.nope", at: "")) =
    cst.update(node:, path: p(["database", "config", "nope"]), with: fn(n) { n })
}

pub fn build_comment_trivia_test() {
  let trivia =
    cst.build_comment_trivia(
      leading: ["First line", "Second line"],
      trailing: None,
    )
  let assert Trivia(leading: tokens, trailing: []) = trivia
  // Synthesized newlines carry empty text; the emitter renders them in the
  // document's line-ending style when the trivia is attached and emitted.
  let assert [
    Token(kind: types.Comment, text: "# First line"),
    Token(kind: types.Newline, text: ""),
    Token(kind: types.Comment, text: "# Second line"),
    Token(kind: types.Newline, text: ""),
  ] = tokens
}

pub fn build_comment_trivia_with_trailing_test() {
  let trivia =
    cst.build_comment_trivia(leading: [], trailing: Some("inline note"))
  let assert Trivia(leading: [], trailing: tokens) = trivia
  let assert [
    Token(kind: types.Whitespace, text: " "),
    Token(kind: types.Comment, text: "# inline note"),
  ] = tokens
}

pub fn trailing_comment_absent_test() {
  let node = cst_parse(docs.config)
  let assert Ok(None) =
    cst.trailing_comment(node:, path: p(["database", "connection", "host"]))
}

pub fn set_trailing_comment_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_trailing_comment(
      node:,
      path: p(["database", "connection", "port"]),
      comment: Some("postgresql default"),
    )
  let doc = cst_to_string(node2)
  assert string.contains(doc, "# postgresql default")
  let assert Ok(Some("# postgresql default")) =
    cst.trailing_comment(
      node: node2,
      path: p(["database", "connection", "port"]),
    )
}

pub fn clear_trailing_comment_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_trailing_comment(
      node:,
      path: p(["database", "connection", "port"]),
      comment: Some("to be removed"),
    )
  let assert Ok(node3) =
    cst.set_trailing_comment(
      node: node2,
      path: p(["database", "connection", "port"]),
      comment: None,
    )
  let assert Ok(None) =
    cst.trailing_comment(
      node: node3,
      path: p(["database", "connection", "port"]),
    )
}

pub fn set_leading_comments_preserves_trailing_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_trailing_comment(
      node:,
      path: p(["database", "connection", "port"]),
      comment: Some("postgresql default"),
    )

  let assert Ok(node3) =
    cst.set_leading_comments(
      node: node2,
      path: p(["database", "connection", "port"]),
      comments: ["Listen port"],
    )

  let assert Ok(Some("# postgresql default")) =
    cst.trailing_comment(
      node: node3,
      path: p(["database", "connection", "port"]),
    )

  let assert Ok(["# Listen port"]) =
    cst.leading_comments(
      node: node3,
      path: p(["database", "connection", "port"]),
    )
}

pub fn colon_in_bare_key_rejected_test() {
  // `key:` is not a valid bare key: colon is not allowed
  let assert Ok(doc) = molt.parse("key: value\n")
  let tree = cst.from_document(doc)
  let assert [N(n), ..] = tree.children
  assert n.kind == types.Error
}

pub fn kv_without_equals_is_error_test() {
  // A line with just a bare key and no `=` should be an Error node
  let assert Ok(doc) = molt.parse("justkey\n")
  let tree = cst.from_document(doc)
  let assert [N(n), ..] = tree.children
  assert n.kind == types.Error
}

pub fn kv_without_value_is_error_test() {
  // A key with equals but no value before newline
  let assert Ok(doc) = molt.parse("key =\n")
  let tree = cst.from_document(doc)
  let assert [N(n), ..] = tree.children
  assert n.kind == types.Error
}

pub fn build_kv_test() {
  let node =
    cst.build_kv(key: "host", value: value.to_cst(value.string("localhost")))
  let assert types.KeyValue = node.kind
  let assert [
    T(Token(kind: types.BareKey, text: "host")),
    T(Token(kind: types.Whitespace, ..)),
    T(Token(kind: types.Equals, ..)),
    T(Token(kind: types.Whitespace, ..)),
    T(Token(kind: types.BasicString, text: "localhost")),
    T(Token(kind: types.Newline, ..)),
  ] = node.children
}

pub fn build_kv_quotes_key_test() {
  let node = cst.build_kv(key: "has space", value: value.to_cst(value.int(1)))
  let assert types.KeyValue = node.kind
  // Key with spaces gets quoted as BasicString
  let assert [T(Token(kind: types.BasicString, ..)), ..] = node.children
}

pub fn build_inline_kv_test() {
  let node = cst.build_inline_kv(key: "x", value: value.to_cst(value.int(42)))
  let assert types.KeyValue = node.kind
  // No trailing newline
  let last = list.last(node.children)
  let assert Ok(T(Token(kind: k, ..))) = last
  assert k != types.Newline
}

pub fn build_table_test() {
  let node = cst.build_table(path: ["server", "database"])
  let assert types.Table = node.kind
  assert [] == cst.list_keys(node)
  assert "[server.database]\n" == cst_to_string(node)
}

pub fn build_array_of_tables_test() {
  let node = cst.build_array_of_tables(path: ["plugins"])
  let assert types.ArrayOfTables = node.kind
  assert [] == cst.list_keys(node)
  assert "[[plugins]]\n" == cst_to_string(node)
}

pub fn zipper_at_indexed_test() {
  let node = cst_parse(docs.config)
  let assert Ok(cursor) =
    cst.zipper_at(node:, path: [KeySegment("plugins"), IndexSegment(1)])
  assert types.ArrayOfTables == cursor.focus.kind
  assert list.contains(cst.list_keys(cursor.focus), "options")
}

pub fn zipper_at_key_in_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(cursor) =
    cst.zipper_at(node:, path: [
      KeySegment("plugins"),
      IndexSegment(1),
      KeySegment("priority"),
    ])
  assert types.KeyValue == cursor.focus.kind
  assert "2" == cst.value_text(cursor.focus)
}

pub fn zipper_at_kv_test() {
  let node = cst_parse(docs.config)
  let assert Ok(cursor) =
    cst.zipper_at(node:, path: p(["database", "connection", "port"]))
  assert types.KeyValue == cursor.focus.kind
  assert Some("port") == cst.key_name(cursor.focus)
}

pub fn zipper_at_table_test() {
  let node = cst_parse(docs.config)
  let assert Ok(cursor) = cst.zipper_at(node:, path: p(["settings"]))
  assert types.Table == cursor.focus.kind
}

pub fn zipper_at_not_found_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(path: "nope", at: "")) =
    cst.zipper_at(node:, path: p(["nope"]))
}

pub fn zipper_at_modify_and_unzip_test() {
  let node = cst_parse(docs.config)
  let assert Ok(cursor) =
    cst.zipper_at(node:, path: p(["database", "connection", "port"]))
  let assert Ok(new_kv) =
    cst.set_kv_value(kv: cursor.focus, value: value.to_cst(value.int(9090)))
  let new_root = zipper.set_focus(zipper: cursor, node: new_kv) |> zipper.unzip
  assert string.contains(cst_to_string(new_root), "port = 9090")
}

pub fn zipper_where_match_test() {
  let node = cst_parse(docs.config)
  let assert Ok(cursor) =
    cst.zipper_where(
      node:,
      path: p(["database", "connection", "port"]),
      where: fn(n) { cst.value_text(n) == "5432" },
    )
  assert types.KeyValue == cursor.focus.kind
  assert Some("port") == cst.key_name(cursor.focus)
}

pub fn zipper_where_no_match_test() {
  let node = cst_parse(docs.config)
  let assert Error(NotFound(
    path: "database.connection.port",
    at: "database.connection",
  )) =
    cst.zipper_where(
      node:,
      path: p(["database", "connection", "port"]),
      where: fn(n) { cst.value_text(n) == "9999" },
    )
}

pub fn zipper_where_duplicate_keys_test() {
  let node = cst_parse("a = 1\na = 2\n")
  let assert Ok(cursor) =
    cst.zipper_where(node:, path: p(["a"]), where: fn(n) {
      cst.value_text(n) == "2"
    })
  assert "2" == cst.value_text(cursor.focus)
}

pub fn get_where_indexed_test() {
  let node = cst_parse(docs.config)
  let assert Ok(kv) =
    cst.get_where(
      node:,
      path: [KeySegment("plugins"), IndexSegment(0), KeySegment("name")],
      where: fn(n) { cst.value_text(n) == "'formatter'" },
    )
  assert "'formatter'" == cst.value_text(kv)
}

pub fn delete_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(entry) =
    cst.get(node:, path: [KeySegment("plugins"), IndexSegment(0)])
  assert False == list.contains(cst.list_keys(entry), "options")

  let assert Ok(node2) =
    cst.delete(node:, path: [KeySegment("plugins"), IndexSegment(0)])
  // After deleting plugins[0] (formatter), linter becomes plugins[0]
  let assert Ok(entry2) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(0)])
  assert list.contains(cst.list_keys(entry2), "options")
}

pub fn delete_key_in_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.delete(node:, path: [
      KeySegment("plugins"),
      IndexSegment(1),
      KeySegment("options"),
    ])
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(1)])
  assert ["name", "priority"] == cst.list_keys(entry)
}

pub fn delete_where_indexed_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.delete_where(
      node:,
      path: [KeySegment("plugins"), IndexSegment(1), KeySegment("name")],
      where: fn(n) { cst.value_text(n) == "'linter'" },
    )
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(1)])
  assert False == list.contains(cst.list_keys(entry), "name")
}

pub fn update_key_in_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.update(
      node:,
      path: [KeySegment("plugins"), IndexSegment(0), KeySegment("priority")],
      with: fn(kv) {
        let assert Ok(updated) =
          cst.set_kv_value(kv:, value: value.to_cst(value.int(99)))
        updated
      },
    )
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(0)])
  let assert Ok(kv) = cst.get(entry, path: p(["priority"]))
  assert "99" == cst.value_text(kv)
}

pub fn update_where_indexed_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.update_where(
      node:,
      path: [KeySegment("plugins"), IndexSegment(0), KeySegment("priority")],
      where: fn(n) { cst.value_text(n) == "1" },
      with: fn(kv) {
        let assert Ok(updated) =
          cst.set_kv_value(kv:, value: value.to_cst(value.int(10)))
        updated
      },
    )
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(0)])
  let assert Ok(kv) = cst.get(entry, path: p(["priority"]))
  assert "10" == cst.value_text(kv)
}

pub fn replace_at_indexed_path_test() {
  let node = cst_parse(docs.config)
  let assert Ok(existing) =
    cst.get(node:, path: [
      KeySegment("plugins"),
      IndexSegment(0),
      KeySegment("priority"),
    ])
  let assert Ok(new_kv) =
    cst.set_kv_value(kv: existing, value: value.to_cst(value.int(10)))
  let assert Ok(node2) =
    cst.replace(
      node:,
      path: [KeySegment("plugins"), IndexSegment(0), KeySegment("priority")],
      new: new_kv,
    )
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(0)])
  let assert Ok(kv) = cst.get(entry, path: p(["priority"]))
  assert "10" == cst.value_text(kv)
}

pub fn rename_key_in_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.rename(
      node:,
      path: [KeySegment("plugins"), IndexSegment(1), KeySegment("name")],
      to: "id",
    )
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(1)])
  assert list.contains(cst.list_keys(entry), "id")
  assert False == list.contains(cst.list_keys(entry), "name")
}

pub fn comments_at_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok([]) =
    cst.leading_comments(node:, path: [
      KeySegment("plugins"),
      IndexSegment(0),
      KeySegment("name"),
    ])
}

pub fn set_comments_at_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.set_leading_comments(
      node:,
      path: [KeySegment("plugins"), IndexSegment(0), KeySegment("name")],
      comments: ["Plugin name"],
    )
  let assert Ok(["# Plugin name"]) =
    cst.leading_comments(node: node2, path: [
      KeySegment("plugins"),
      IndexSegment(0),
      KeySegment("name"),
    ])
}

pub fn move_from_indexed_entry_test() {
  let node = cst_parse(docs.config)
  let assert Ok(node2) =
    cst.move(
      node:,
      from: [KeySegment("plugins"), IndexSegment(0), KeySegment("priority")],
      to: p(["formatter_priority"]),
    )
  let assert Ok(entry) =
    cst.get(node: node2, path: [KeySegment("plugins"), IndexSegment(0)])
  assert False == list.contains(cst.list_keys(entry), "priority")
  let assert Ok(kv) = cst.get(node: node2, path: p(["formatter_priority"]))
  assert "1" == cst.value_text(kv)
}

pub fn negative_index_test() {
  let node = cst_parse(docs.config)
  // IndexSegment(-1) resolves to the last plugins entry (linter, with options)
  let assert Ok(entry) =
    cst.get(node:, path: [KeySegment("plugins"), IndexSegment(-1)])
  assert list.contains(cst.list_keys(entry), "options")
}

pub fn zipper_where_indexed_test() {
  let assert Ok(cursor) =
    cst_parse(docs.config)
    |> cst.zipper_where(
      path: [KeySegment("plugins"), IndexSegment(1), KeySegment("priority")],
      where: fn(n) { cst.value_text(n) == "2" },
    )
  assert "2" == cst.value_text(cursor.focus)
}

pub fn value_text_with_inline_comment_test() {
  let doc = cst_parse("port = 80 # http\n")
  let assert [greenwood.NodeElement(kv)] = doc.children
  assert "80" == cst.value_text(kv)
}

pub fn update_value_preserves_comment_test() {
  let doc = cst_parse("port = 80 # http\n")
  let assert [greenwood.NodeElement(kv)] = doc.children
  let assert Ok(updated_kv) =
    cst.set_kv_value(kv:, value: value.to_cst(value.int(443)))
  let updated_doc =
    greenwood.Node(..doc, children: [greenwood.NodeElement(updated_kv)])

  assert "port = 443 # http\n" == cst_to_string(updated_doc)
}

pub fn rename_table_dotted_test() {
  let doc = cst_parse("[tools.pontil_build.bundle]\nkey = 1\n")
  let assert Ok(updated) =
    cst.rename(
      node: doc,
      path: [
        KeySegment("tools"),
        KeySegment("pontil_build"),
        KeySegment("bundle"),
      ],
      to: "assets",
    )
  assert "[tools.pontil_build.assets]\nkey = 1\n" == cst_to_string(updated)
}

pub fn cst_parse_path_test() {
  assert Ok([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("c"),
      KeySegment("d"),
    ])
    == cst.parse_path("a.b.c.d")
  assert Ok([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("-1"),
      KeySegment("d"),
    ])
    == cst.parse_path("a.b.-1.d")
  assert Ok([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("with space"),
      KeySegment("d"),
    ])
    == cst.parse_path("a.b.\"with space\".d")
  assert Ok([
      KeySegment("a"),
      KeySegment("b"),
      KeySegment("\f"),
      KeySegment("\\f"),
    ])
    == cst.parse_path("a.b.\"\f\".'\\f'")
  assert Ok([
      KeySegment("a"),
      KeySegment("b"),
      IndexSegment(-1),
      KeySegment("c"),
    ])
    == cst.parse_path("a.b[-1].c")
  assert Ok([
      KeySegment("a"),
      KeySegment("b"),
      IndexSegment(3),
      KeySegment("c"),
    ])
    == cst.parse_path("a.b[3].c")

  assert Error(InvalidPath("non-integer in brackets: c"))
    == cst.parse_path("a[c]")
}

fn cst_parse(document: String) {
  let assert Ok(tree) =
    molt.parse(document)
    |> result.map(cst.from_document)

  tree
}

fn cst_to_string(node: Node(TomlKind)) -> String {
  cst.to_document(node) |> molt.to_string
}

fn p(parts: List(String)) -> List(PathSegment) {
  list.map(parts, KeySegment)
}

fn idx(haystack: String, needle: String) -> Int {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(_) -> -1
  }
}

fn build_kv(key: String) -> Node(TomlKind) {
  cst.build_kv(key:, value: value.to_cst(value.bool(True)))
}

fn marked_entry(path: List(String), marker: String) -> Node(TomlKind) {
  greenwood.append_child(
    in: cst.build_array_of_tables(path),
    child: N(build_kv(marker)),
  )
}

const aot_sub = "[[a.b]]
x = 1

[[a.b]]
y = 2

[a.b.sub]
z = 3

[c]
w = 4
"
