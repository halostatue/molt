//// Document index and path resolution for document operations.

import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import greenwood.{
  type Element, type Node, NodeElement as N, Token, TokenElement as T,
}
import molt/error.{type MoltError}
import molt/internal/cst/elements
import molt/internal/path
import molt/internal/utils
import molt/types.{
  type Document, type DocumentIndex, type IndexEntry, type IndexKey, type Path,
  type PathSegment, type TomlKind, Document, IndexKey, IndexSegment, KeySegment,
}
import molt/value

/// What the index says about a given path.
pub type Resolution {
  /// The exact path exists in the index.
  Hit(path: Path, entry: IndexEntry)

  /// The exact path does not exist. `ancestor` is the deepest existing
  /// ancestor; `tail` is the remaining path below it.
  ///
  /// A Miss is NOT an error: it means "create at the ancestor."
  Miss(ancestor_path: Path, ancestor: IndexEntry, tail: Path)

  /// Nothing at or above this path exists in the index.
  ///
  /// A Fresh is NOT an error for write operations: it means "create at root."
  Fresh(path: Path)
}

/// Where in the CST a new node should be inserted.
/// Derived from the ancestor's `IndexEntry` on a Miss or Fresh resolution.
pub type InsertionSite {
  /// Append to the concrete table or array of tables entry at this path.
  /// The zipper can navigate directly to this concrete node.
  ConcreteAppend(container: Path)

  /// Emit as a root-level dotted key using the full path.
  ///
  /// Used when the nearest container is an implicit table (no concrete node).
  /// The new KV must be inserted BEFORE the first concrete `[table]` /
  /// `[[AoT]]` header at root to remain valid TOML.
  RootDottedKey(full_path: Path)

  /// Navigate into an inline value (inline table / array) for the insertion.
  InlineDescend(full_path: Path)
}

/// Build the document index from the root node of a document tree.
pub fn build_tree_index(tree: Node(TomlKind)) -> DocumentIndex {
  // Phase 1: Walk CST, register all explicit nodes
  index_table_kvs(index: dict.new(), nodes: tree.children, path: [])
  |> index_tables(nodes: tree.children)
  // Phase 2: Populate children bottom-up and add key-only AoT entries
  |> enrich_children()
}

pub fn with_index(
  doc doc: Document,
  callback callback: fn(DocumentIndex) -> Result(a, MoltError),
) -> Result(a, MoltError) {
  use index <- result.try(get_index(doc))
  callback(index)
}

pub fn get_index(doc: Document) -> Result(DocumentIndex, MoltError) {
  use doc <- result.try(ensure_index(doc))
  Ok(option.unwrap(doc.index, or: dict.new()))
}

pub fn has_path(index index: DocumentIndex, path path: Path) -> Bool {
  has_key(index:, key: path_to_index_key(path))
}

pub fn has_key(index index: DocumentIndex, key key: IndexKey) -> Bool {
  dict.has_key(index, key)
}

pub fn get_path(
  index index: DocumentIndex,
  path path: Path,
) -> Result(IndexEntry, Nil) {
  get(index:, key: path_to_index_key(path))
}

pub fn get(
  index index: DocumentIndex,
  key key: IndexKey,
) -> Result(IndexEntry, Nil) {
  dict.get(index, key)
}

/// Resolve a path against the document index.
pub fn resolve(idx idx: DocumentIndex, path path: Path) -> Resolution {
  let key = path_to_index_key(path)
  case get(index: idx, key:) {
    Ok(entry) -> Hit(path:, entry:)
    Error(Nil) ->
      case find_deepest_ancestor(idx:, key:) {
        Ok(#(ancestor_key, ancestor)) -> {
          let ancestor_path = key_to_path(ancestor_key)
          let tail = list.drop(path, list.length(ancestor_path))
          Miss(ancestor_path:, ancestor:, tail:)
        }
        Error(Nil) -> Fresh(path:)
      }
  }
}

/// Derive the insertion site for a Miss or Fresh resolution.
///
/// `ancestor_path` and `ancestor` describe the deepest existing ancestor.
/// `full_path` is the complete target path (ancestor_path ++ tail, or just
/// path for Fresh).
pub fn insertion_site(
  idx idx: types.DocumentIndex,
  ancestor_path ancestor_path: Path,
  ancestor ancestor: IndexEntry,
  full_path full_path: Path,
) -> Result(InsertionSite, MoltError) {
  case ancestor {
    types.IndexTable(..) | types.IndexArrayOfTablesEntry(..) ->
      Ok(ConcreteAppend(ancestor_path))

    types.IndexImplicitTable(..) ->
      Ok(find_concrete_ancestor_site(
        idx:,
        implicit_path: ancestor_path,
        full_path:,
      ))

    types.IndexScalarValue(..)
    | types.IndexArrayValue(..)
    | types.IndexInlineTableValue(..) -> Ok(InlineDescend(full_path))

    types.IndexArrayOfTables(..) ->
      Error(error.TypeMismatch(
        path: option.Some(path.to_string(ancestor_path)),
        expected: "a table (use an index to select an entry)",
        got: "array of tables",
      ))
  }
}

pub fn rename_key(path path: Path, to to: String) -> IndexKey {
  case path_to_index_key(path) {
    IndexKey([_last, ..rest]) -> IndexKey([KeySegment(to), ..rest])
    key -> key
  }
}

/// Create an IndexKey from a path.
pub fn path_to_index_key(path: Path) -> IndexKey {
  IndexKey(list.reverse(path))
}

/// Convert an IndexKey back to a forward path.
pub fn key_to_path(key: IndexKey) -> Path {
  let IndexKey(reversed) = key
  list.reverse(reversed)
}

/// Get root-level key names from the index (entries with single KeySegment keys).
pub fn root_children(idx: DocumentIndex) -> List(String) {
  dict.fold(idx, [], fn(acc, key, _entry) {
    case key {
      IndexKey([KeySegment(name)]) -> [name, ..acc]
      _ -> acc
    }
  })
}

/// Find the deepest existing ancestor of a path in the index.
/// Returns the entry and its IndexKey, or Error if nothing exists.
/// Walks up by popping the head of the reversed key: O(1) per level.
pub fn find_deepest_ancestor_entry(
  idx idx: DocumentIndex,
  key key: IndexKey,
) -> Result(IndexEntry, Nil) {
  use #(_, entry) <- result.try(find_deepest_ancestor(idx:, key:))
  Ok(entry)
}

// --- Index patch helpers ---
// These mutate a DocumentIndex incrementally without a full tree walk.

/// Classify what IndexEntry type a Value produces.
pub fn entry_for_value(
  val val: value.Value,
  container container: Path,
) -> IndexEntry {
  case value.type_of(val) {
    "array" -> types.IndexArrayValue(container:)
    "inline_table" -> types.IndexInlineTableValue(container:)
    "table" -> types.IndexInlineTableValue(container:)
    _ -> types.IndexScalarValue(container:)
  }
}

/// Classify what IndexEntry type a CST element produces.
/// Used to update the index when replacing a value via cursor.
pub fn entry_for_element(
  el el: Element(TomlKind),
  container container: Path,
) -> IndexEntry {
  case el {
    N(n) if n.kind == types.InlineTable ->
      types.IndexInlineTableValue(container:)
    N(n) if n.kind == types.Array -> types.IndexArrayValue(container:)
    _ -> types.IndexScalarValue(container:)
  }
}

/// Insert a new entry and register it as a child of its parent.
pub fn insert_entry(
  idx idx: DocumentIndex,
  key key: IndexKey,
  entry entry: IndexEntry,
) -> DocumentIndex {
  let idx = dict.insert(idx, key, entry)
  add_child_to_parent(idx:, key:)
}

/// Remove an entry and all entries whose keys are descendants of it.
pub fn remove_subtree(
  idx idx: DocumentIndex,
  key key: IndexKey,
) -> DocumentIndex {
  let idx = dict.delete(idx, key)
  let idx = remove_child_from_parent(idx:, key:)
  // Remove all keys that have `key` as a prefix (i.e., key's segments are a
  // suffix of the reversed key in each candidate).
  let IndexKey(prefix_rev) = key
  dict.fold(idx, idx, fn(acc, candidate, _) {
    case is_descendant_of(child: candidate, parent_rev: prefix_rev) {
      True -> dict.delete(acc, candidate)
      False -> acc
    }
  })
}

/// After removing a subtree, prune any implicit table ancestors that now
/// have empty children lists. Walks upward from the removed key's parent.
pub fn prune_empty_implicit_ancestors(
  idx idx: DocumentIndex,
  key key: IndexKey,
) -> DocumentIndex {
  case parent_key(key) {
    Error(Nil) -> idx
    Ok(parent) ->
      case dict.get(idx, parent) {
        Ok(types.IndexImplicitTable(children: [])) -> {
          let idx = dict.delete(idx, parent)
          let idx = remove_child_from_parent(idx:, key: parent)
          prune_empty_implicit_ancestors(idx:, key: parent)
        }
        _ -> idx
      }
  }
}

/// Update the entry at key in-place (e.g., change scalar to inline table).
pub fn update_entry(
  idx idx: DocumentIndex,
  key key: IndexKey,
  entry entry: IndexEntry,
) -> DocumentIndex {
  dict.insert(idx, key, entry)
}

/// Ensure implicit table entries exist for all ancestor segments of a path.
/// Does not overwrite existing entries.
pub fn ensure_implicit_tables(
  idx idx: DocumentIndex,
  path path: Path,
) -> DocumentIndex {
  let prefixes = utils.all_prefixes(path:)
  list.fold(prefixes, idx, fn(idx, prefix) {
    let key = path_to_index_key(prefix)
    case dict.get(idx, key) {
      Error(Nil) ->
        insert_entry(idx:, key:, entry: types.IndexImplicitTable(children: []))
      Ok(_) -> idx
    }
  })
}

// Use for tests only
pub fn build_doc_index(doc: Document) -> Option(DocumentIndex) {
  Some(build_tree_index(doc.tree))
}

/// Check if child's reversed key has parent_rev as a suffix
/// (meaning parent is an ancestor of child).
fn is_descendant_of(
  child child: IndexKey,
  parent_rev parent_rev: List(PathSegment),
) -> Bool {
  let IndexKey(child_rev) = child
  list.length(child_rev) > list.length(parent_rev)
  && has_suffix(child_rev, parent_rev)
}

fn has_suffix(longer: List(PathSegment), suffix: List(PathSegment)) -> Bool {
  let drop_count = list.length(longer) - list.length(suffix)
  list.drop(longer, drop_count) == suffix
}

/// Register a child name with its parent entry.
fn add_child_to_parent(
  idx idx: DocumentIndex,
  key key: IndexKey,
) -> DocumentIndex {
  case key {
    IndexKey([KeySegment(child), ..parent_rev]) -> {
      let parent = IndexKey(parent_rev)
      case dict.get(idx, parent) {
        Ok(entry) -> dict.insert(idx, parent, entry_add_child(entry, child))
        Error(Nil) -> idx
      }
    }
    _ -> idx
  }
}

/// Remove a child name from its parent entry's children list.
fn remove_child_from_parent(
  idx idx: DocumentIndex,
  key key: IndexKey,
) -> DocumentIndex {
  case key {
    IndexKey([KeySegment(child), ..parent_rev]) -> {
      let parent = IndexKey(parent_rev)
      case dict.get(idx, parent) {
        Ok(entry) -> dict.insert(idx, parent, entry_remove_child(entry, child))
        Error(Nil) -> idx
      }
    }
    _ -> idx
  }
}

fn entry_remove_child(
  entry: types.IndexEntry,
  child: String,
) -> types.IndexEntry {
  case entry {
    types.IndexTable(children:) ->
      types.IndexTable(children: list.filter(children, fn(c) { c != child }))
    types.IndexImplicitTable(children:) ->
      types.IndexImplicitTable(
        children: list.filter(children, fn(c) { c != child }),
      )
    types.IndexArrayOfTables(count:, children:) ->
      types.IndexArrayOfTables(
        count:,
        children: list.filter(children, fn(c) { c != child }),
      )
    types.IndexArrayOfTablesEntry(parent:, index: i, children:) ->
      types.IndexArrayOfTablesEntry(
        parent:,
        index: i,
        children: list.filter(children, fn(c) { c != child }),
      )
    _ -> entry
  }
}

/// Relocate a subtree from one key to another (move operation).
/// Removes all entries under `from` and inserts them under `to`.
pub fn relocate_subtree(
  idx idx: DocumentIndex,
  from from: IndexKey,
  to to: IndexKey,
) -> DocumentIndex {
  let IndexKey(from_rev) = from
  let IndexKey(to_rev) = to
  let from_len = list.length(from_rev)
  let from_path = key_to_path(from)
  let to_path = key_to_path(to)

  // Collect entries to move (from itself + descendants)
  let to_move =
    dict.fold(idx, [], fn(acc, key, entry) {
      case key == from {
        True -> [#(to, relocate_container(entry:, from_path:, to_path:)), ..acc]
        False ->
          case is_descendant_of(child: key, parent_rev: from_rev) {
            True -> {
              // Replace the from prefix with to prefix
              let IndexKey(key_rev) = key
              let suffix = list.take(key_rev, list.length(key_rev) - from_len)
              let new_key = IndexKey(list.append(suffix, to_rev))
              [
                #(new_key, relocate_container(entry:, from_path:, to_path:)),
                ..acc
              ]
            }
            False -> acc
          }
      }
    })

  // Remove old entries
  let idx = remove_subtree(idx:, key: from)
  // Insert new entries
  list.fold(to_move, idx, fn(idx, pair) {
    let #(key, entry) = pair
    insert_entry(idx:, key:, entry:)
  })
}

/// Update the container path in a value entry when relocating.
fn relocate_container(
  entry entry: types.IndexEntry,
  from_path from_path: Path,
  to_path to_path: Path,
) -> types.IndexEntry {
  case entry {
    types.IndexScalarValue(container:) ->
      types.IndexScalarValue(container: remap_container(
        container:,
        from_path:,
        to_path:,
      ))
    types.IndexArrayValue(container:) ->
      types.IndexArrayValue(container: remap_container(
        container:,
        from_path:,
        to_path:,
      ))
    types.IndexInlineTableValue(container:) ->
      types.IndexInlineTableValue(container: remap_container(
        container:,
        from_path:,
        to_path:,
      ))
    _ -> entry
  }
}

/// If container starts with from_path (or a prefix of it), replace that
/// prefix with the corresponding portion of to_path.
fn remap_container(
  container container: Path,
  from_path from_path: Path,
  to_path to_path: Path,
) -> Path {
  let from_len = list.length(from_path)
  let container_len = list.length(container)
  case list.take(container, from_len) == from_path {
    // Container starts with the full from_path
    True -> list.append(to_path, list.drop(container, from_len))
    False ->
      // Check if from_path starts with container (container is an ancestor)
      case
        from_len >= container_len
        && list.take(from_path, container_len) == container
      {
        True -> list.take(to_path, container_len)
        False -> container
      }
  }
}

fn index_table_kvs(
  index index: DocumentIndex,
  nodes nodes: List(Element(TomlKind)),
  path path: Path,
) -> DocumentIndex {
  list.fold(nodes, index, fn(index, node) {
    case node {
      N(kv) if kv.kind == types.KeyValue -> index_kv_node(index:, kv:, path:)
      _ -> index
    }
  })
}

fn index_tables(
  nodes nodes: List(Element(TomlKind)),
  index index: DocumentIndex,
) -> DocumentIndex {
  list.fold(nodes, index, fn(index, node) {
    case node {
      N(n) if n.kind == types.Table -> {
        let path =
          list.map(elements.extract_key_segments(n.children), KeySegment)
          |> resolve_header_path(index)
        index_table_kvs(
          nodes: n.children,
          path:,
          index: register_table_path(path, index),
        )
      }

      N(n) if n.kind == types.ArrayOfTables -> {
        let path =
          list.map(elements.extract_key_segments(n.children), KeySegment)
          |> resolve_header_path(index)

        let index = register_array_of_tables_path(path, index)

        // Use count-1 as the zero-based index for this entry
        let entry_index = case dict.get(index, path_to_index_key(path)) {
          Ok(types.IndexArrayOfTables(count:, ..)) -> count - 1
          _ -> 0
        }
        let segment = IndexSegment(entry_index) |> list.wrap
        let entry_path = list.append(path, segment)
        // Register the instance path
        let index =
          dict.insert(
            index,
            path_to_index_key(entry_path),
            types.IndexArrayOfTablesEntry(
              parent: path,
              index: entry_index,
              children: [],
            ),
          )
        index_table_kvs(nodes: n.children, path: entry_path, index:)
      }
      _ -> index
    }
  })
}

/// Resolve a header's key-only path against the index, inserting IndexSegments
/// where parent array tables exist. E.g., [a, b, d] when a.b is an array table
/// with 3 entries becomes [a, b, IndexSegment(2), d].
fn resolve_header_path(key_path: Path, index: DocumentIndex) -> Path {
  do_resolve_header_path(remaining: key_path, built: [], index:)
}

fn do_resolve_header_path(
  remaining remaining: Path,
  built built: Path,
  index index: DocumentIndex,
) -> Path {
  case remaining {
    [] -> built
    // Last segment: this is the table being defined, don't inject index
    [segment] -> list.append(built, [segment])
    [segment, ..rest] -> {
      let candidate = list.append(built, [segment])
      case dict.get(index, path_to_index_key(candidate)) {
        Ok(types.IndexArrayOfTables(count:, ..)) -> {
          // Insert IndexSegment for the last entry of this array table
          let with_index = list.append(candidate, [IndexSegment(count - 1)])
          do_resolve_header_path(remaining: rest, built: with_index, index:)
        }
        _ -> do_resolve_header_path(remaining: rest, built: candidate, index:)
      }
    }
  }
}

/// Rewrite negative index segments that target an array of tables to their
/// positive equivalent, using the family's tracked `count` (e.g. `a[-1]` with
/// 3 entries becomes `a[2]`). Index segments that target an array *value* are
/// left untouched — the index carries no length for them, so structural
/// navigation resolves those (it is already negative-aware).
///
/// Callers keep the original path for error reporting; this is only for lookup.
pub fn resolve_negative_indices(
  idx idx: DocumentIndex,
  path path: Path,
) -> Path {
  do_resolve_negative_indices(remaining: path, built: [], index: idx)
}

fn do_resolve_negative_indices(
  remaining remaining: Path,
  built built: Path,
  index index: DocumentIndex,
) -> Path {
  case remaining {
    [] -> built
    [IndexSegment(i), ..rest] -> {
      let resolved = case i < 0, dict.get(index, path_to_index_key(built)) {
        True, Ok(types.IndexArrayOfTables(count:, ..)) -> count + i
        _, _ -> i
      }
      do_resolve_negative_indices(
        remaining: rest,
        built: list.append(built, [IndexSegment(resolved)]),
        index:,
      )
    }
    [segment, ..rest] ->
      do_resolve_negative_indices(
        remaining: rest,
        built: list.append(built, [segment]),
        index:,
      )
  }
}

fn index_kv_node(
  kv kv: Node(TomlKind),
  path path: Path,
  index index: DocumentIndex,
) -> DocumentIndex {
  case elements.key_path(kv.children) {
    None -> index
    Some(segments) -> {
      let key_segments = list.map(segments, KeySegment)
      let full_path = list.append(path, key_segments)
      // Register implicit parents for dotted keys
      let index = register_dotted_parents(path:, segments: key_segments, index:)
      // Classify the value
      let entry = classify_kv_value(kv, container: path)
      dict.insert(index, path_to_index_key(full_path), entry)
    }
  }
}

fn register_dotted_parents(
  path path: Path,
  segments segments: Path,
  index index: DocumentIndex,
) -> DocumentIndex {
  case segments {
    [] | [_] -> index
    _ -> {
      // All prefixes of segments (excluding the full path)
      let prefix_segments = utils.all_prefixes(path: segments)
      list.fold(prefix_segments, index, fn(index, prefix) {
        let full = list.append(path, prefix)
        let key = path_to_index_key(full)
        case dict.get(index, key) {
          Error(Nil) ->
            dict.insert(index, key, types.IndexImplicitTable(children: []))
          Ok(_) -> index
        }
      })
    }
  }
}

fn register_table_path(path: Path, index: DocumentIndex) -> DocumentIndex {
  // Register implicit parents
  let index = register_header_parents(path, index)
  // Register the table itself
  dict.insert(index, path_to_index_key(path), types.IndexTable(children: []))
}

fn register_array_of_tables_path(
  path: Path,
  index: DocumentIndex,
) -> DocumentIndex {
  // Register implicit parents
  let index = register_header_parents(path, index)
  // Increment count or set to 1
  let key = path_to_index_key(path)
  let count = case dict.get(index, key) {
    Ok(types.IndexArrayOfTables(c, ..)) -> c + 1
    _ -> 1
  }
  dict.insert(index, key, types.IndexArrayOfTables(count:, children: []))
}

fn register_header_parents(path: Path, index: DocumentIndex) -> DocumentIndex {
  let prefixes = utils.all_prefixes(path:)
  list.fold(prefixes, index, fn(index, prefix) {
    let key = path_to_index_key(prefix)
    case dict.get(index, key) {
      Error(Nil) ->
        dict.insert(index, key, types.IndexImplicitTable(children: []))
      Ok(_) -> index
    }
  })
}

fn classify_kv_value(
  kv: Node(TomlKind),
  container container: Path,
) -> types.IndexEntry {
  elements.value_tokens(kv.children)
  |> classify_value_tokens(container:)
}

fn classify_value_tokens(
  nodes: List(Element(TomlKind)),
  container container: Path,
) -> types.IndexEntry {
  case nodes {
    [] -> types.IndexScalarValue(container:)
    [T(Token(kind: types.Whitespace, ..)), ..rest]
    | [T(Token(kind: types.Newline, ..)), ..rest] ->
      classify_value_tokens(rest, container:)
    [N(n), ..] if n.kind == types.InlineTable ->
      types.IndexInlineTableValue(container:)
    [N(n), ..] if n.kind == types.Array -> types.IndexArrayValue(container:)
    _ -> types.IndexScalarValue(container:)
  }
}

/// Enrich index entries with children lists and add key-only canonical
/// entries for AoTs that live under IndexSegment-bearing paths.
fn enrich_children(raw: DocumentIndex) -> DocumentIndex {
  // For each entry, find its parent (stripping the first element of the
  // reversed key) and register the child name with the parent.
  dict.fold(raw, raw, fn(idx, key, _entry) {
    case key {
      // Root-level entry: add to virtual root (empty key)
      IndexKey([KeySegment(child)]) ->
        add_child_to_entry(idx:, parent: IndexKey([]), child:)

      // Child name is first segment of reversed key (if KeySegment)
      IndexKey([KeySegment(child), ..parent]) -> {
        let parent = IndexKey(parent)
        use <- bool.guard(!dict.has_key(idx, parent), return: idx)

        add_child_to_entry(idx:, parent:, child:)
      }
      _ -> idx
    }
  })
  |> add_canonical_aot_entries(raw)
}

/// Add a child name to a parent entry's children list (dedup).
fn add_child_to_entry(
  idx idx: DocumentIndex,
  parent parent: IndexKey,
  child child: String,
) -> DocumentIndex {
  case parent {
    // Don't add a synthetic root entry: root children are derived on demand
    IndexKey([]) -> idx
    _ ->
      case dict.get(idx, parent) {
        Ok(entry) -> dict.insert(idx, parent, entry_add_child(entry, child))
        Error(Nil) -> idx
      }
  }
}

fn entry_add_child(entry: types.IndexEntry, child: String) -> types.IndexEntry {
  case entry {
    types.IndexTable(children:) ->
      case list.contains(children, child) {
        True -> entry
        False -> types.IndexTable(children: [child, ..children])
      }
    types.IndexImplicitTable(children:) ->
      case list.contains(children, child) {
        True -> entry
        False -> types.IndexImplicitTable(children: [child, ..children])
      }
    types.IndexArrayOfTables(count:, children:) ->
      case list.contains(children, child) {
        True -> entry
        False -> types.IndexArrayOfTables(count:, children: [child, ..children])
      }
    types.IndexArrayOfTablesEntry(parent:, index: i, children:) ->
      case list.contains(children, child) {
        True -> entry
        False ->
          types.IndexArrayOfTablesEntry(parent:, index: i, children: [
            child,
            ..children
          ])
      }
    // Scalar/inline/array values don't have children
    _ -> entry
  }
}

/// For AoTs that are nested under IndexSegment-bearing paths, add a canonical
/// key-only entry ONLY if the AoT exists under exactly one parent scope
/// (unambiguous). If it exists under multiple parent entries, the key-only path
/// is ambiguous and should not be created.
fn add_canonical_aot_entries(
  idx: DocumentIndex,
  raw: DocumentIndex,
) -> DocumentIndex {
  // First, collect all canonical keys and count how many scoped versions exist
  let canonical_counts =
    dict.fold(raw, dict.new(), fn(acc, key, entry) {
      case entry {
        types.IndexArrayOfTables(..) -> {
          let IndexKey(key) = key

          use <- bool.guard(!path.contains_index(key), return: acc)

          let canonical_key =
            list.filter(key, is_key_segment)
            |> IndexKey()

          dict.upsert(acc, canonical_key, fn(v) { option.unwrap(v, or: 0) + 1 })
        }
        _ -> acc
      }
    })

  // Only insert canonical entries where there's exactly one scoped version
  dict.fold(raw, idx, fn(idx, key, entry) {
    case entry {
      types.IndexArrayOfTables(..) -> {
        let IndexKey(key) = key

        use <- bool.guard(!path.contains_index(key), return: idx)

        let canonical_key =
          list.filter(key, is_key_segment)
          |> IndexKey()

        use <- bool.guard(
          dict.get(canonical_counts, canonical_key) != Ok(1),
          return: idx,
        )

        // Only one scoped version: safe to add canonical
        dict.upsert(idx, canonical_key, fn(v) { option.unwrap(v, or: entry) })
      }
      _ -> idx
    }
  })
}

fn is_key_segment(seg: PathSegment) -> Bool {
  case seg {
    KeySegment(_) -> True
    _ -> False
  }
}

fn ensure_index(doc: Document) -> Result(Document, MoltError) {
  use <- bool.guard(doc.error_count > 0, return: Error(error.InvalidDocument))

  use <- bool.guard(doc.index != None, return: Ok(doc))

  Ok(Document(..doc, index: Some(build_tree_index(doc.tree))))
}

/// Get the parent key of the current index key. Returns Error(Nil) if already
/// at the root.
fn parent_key(key: IndexKey) -> Result(IndexKey, Nil) {
  case key {
    IndexKey([_, ..rest]) -> Ok(IndexKey(rest))
    IndexKey([]) -> Error(Nil)
  }
}

/// Walk upward from an implicit table path to find the nearest concrete
/// (IndexTable or IndexArrayOfTablesEntry) ancestor. Returns ConcreteAppend
/// for that ancestor, or RootDottedKey if only implicit tables exist above.
fn find_concrete_ancestor_site(
  idx idx: types.DocumentIndex,
  implicit_path implicit_path: Path,
  full_path full_path: Path,
) -> InsertionSite {
  let parent = list.take(implicit_path, list.length(implicit_path) - 1)
  case parent {
    [] -> RootDottedKey(full_path)
    _ ->
      case get_path(index: idx, path: parent) {
        Ok(types.IndexTable(..)) | Ok(types.IndexArrayOfTablesEntry(..)) ->
          ConcreteAppend(parent)
        Ok(types.IndexImplicitTable(..)) ->
          find_concrete_ancestor_site(idx:, implicit_path: parent, full_path:)
        _ -> RootDottedKey(full_path)
      }
  }
}

/// Find the deepest existing ancestor of a path in the index.
/// Returns the entry and its IndexKey, or Error if nothing exists.
/// Walks up by popping the head of the reversed key: O(1) per level.
fn find_deepest_ancestor(
  idx idx: DocumentIndex,
  key key: IndexKey,
) -> Result(#(IndexKey, IndexEntry), Nil) {
  case dict.get(idx, key) {
    Ok(entry) -> Ok(#(key, entry))
    Error(Nil) ->
      case parent_key(key) {
        Ok(parent) -> find_deepest_ancestor(idx:, key: parent)
        Error(Nil) -> Error(Nil)
      }
  }
}
