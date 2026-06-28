import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import greenwood.{
  type Element, type Node, Node, NodeElement as N, Token, TokenElement as T,
}
import greenwood/zipper
import molt/cst
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/document/index.{Fresh, Hit, Miss, RootDottedKey}
import molt/internal/document/primitives
import molt/internal/document/remove
import molt/internal/document/structure
import molt/internal/path
import molt/internal/utils
import molt/ops
import molt/types.{
  type Document, type Path, type TomlKind, IndexScalarValue, KeySegment,
}
import molt/value

pub fn rename(
  doc doc: Document,
  path p: String,
  to to: String,
) -> Result(Document, MoltError) {
  use <- bool.guard(
    p == "",
    return: Error(error.InvalidOperation("rename", None)),
  )
  use segments <- result.try(path.parse(p))
  use <- bool.guard(
    case path.split_last_segment(segments) {
      #(_, KeySegment(_)) -> False
      _ -> True
    },
    return: Error(error.TypeMismatch(
      path: Some(p),
      expected: "a key",
      got: "an index segment",
    )),
  )
  use idx <- index.with_index(doc)

  // Source first (mv semantics): you can't rename what isn't there, and an
  // un-renameable source also outranks a destination name collision.
  case index.resolve(idx, segments) {
    Miss(..) | Fresh(_) -> Error(error.not_found(p))

    Hit(_, types.IndexArrayOfTablesEntry(..)) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "a named key",
        got: "array of tables entry",
      ))

    Hit(_, entry) ->
      // Source exists and is renameable; a destination collision comes next.
      case index.get(index: idx, key: index.rename_key(path: segments, to:)) {
        Ok(current) ->
          Error(error.AlreadyExists(
            path: path.to_string(
              list.append(path.drop_last_segment(segments), [KeySegment(to)]),
            ),
            current:,
          ))

        _ ->
          case entry {
            types.IndexImplicitTable(..) -> {
              let #(parent, _) = path.split_last_segment(segments)
              let to_segments = list.append(parent, [KeySegment(to)])
              move_implicit_table(doc:, idx:, from: segments, to: to_segments)
            }

            // An array of tables family is many sibling `[[srv]]` headers (plus
            // any nested `[[srv.sub]]`). Renaming the family must rewrite the
            // prefix on every one of them, not just the first — so use the
            // prefix rewrite, not single-node `cst.rename`. Rebuild, since many
            // headers and their index entries change.
            types.IndexArrayOfTables(..) -> {
              let from_keys = path.path_to_table_header(segments)
              let #(parent, _) = path.split_last_segment(segments)
              let to_keys =
                path.path_to_table_header(list.append(parent, [KeySegment(to)]))
              let new_children =
                rewrite_header_prefix(
                  children: doc.tree.children,
                  from_keys:,
                  to_keys:,
                )
              Ok(primitives.rebuild(
                doc:,
                tree: Node(..doc.tree, children: new_children),
              ))
            }

            _ -> {
              use new_tree <- result.try(cst.rename(
                node: doc.tree,
                path: segments,
                to:,
              ))
              let from_key = index.path_to_index_key(segments)
              let to_key = index.rename_key(path: segments, to:)
              let idx = index.relocate_subtree(idx:, from: from_key, to: to_key)
              Ok(primitives.patch(doc:, tree: new_tree, idx:))
            }
          }
      }
  }
}

pub fn move(
  doc doc: Document,
  from from: String,
  to to: String,
) -> Result(Document, MoltError) {
  use from_segments <- result.try(path.parse(from))
  use to_segments <- result.try(path.parse(to))
  use idx <- index.with_index(doc)

  // Source first (mv semantics): a missing source beats a destination collision.
  let resolution = index.resolve(idx, from_segments)
  use <- bool.guard(
    case resolution {
      Miss(..) | Fresh(_) -> True
      _ -> False
    },
    return: Error(error.not_found(from)),
  )

  let maybe_existing_at_to = index.get_path(index: idx, path: to_segments)
  use <- bool.guard(
    result.is_ok(maybe_existing_at_to),
    return: case path.split_last_segment(to_segments) {
      #(_, KeySegment(_)) ->
        Error(error.AlreadyExists(
          path: to,
          current: result.unwrap(
            maybe_existing_at_to,
            IndexScalarValue(container: []),
          ),
        ))
      _ ->
        Error(error.TypeMismatch(
          path: Some(to),
          expected: "a key",
          got: "an index segment",
        ))
    },
  )

  case resolution {
    Hit(_, types.IndexImplicitTable(..)) ->
      move_implicit_table(doc:, idx:, from: from_segments, to: to_segments)

    Hit(_, types.IndexTable(..)) | Hit(_, types.IndexArrayOfTables(..)) -> {
      use new_tree <- result.try(cst.move(
        node: doc.tree,
        from: from_segments,
        to: to_segments,
      ))
      let from_key = index.path_to_index_key(from_segments)
      let to_key = index.path_to_index_key(to_segments)
      let idx = index.relocate_subtree(idx:, from: from_key, to: to_key)
      Ok(primitives.patch(doc:, tree: new_tree, idx:))
    }

    Hit(_, _) -> move_kv(doc:, idx:, from: from_segments, to: to_segments)

    Miss(..) | Fresh(_) -> Error(error.not_found(from))
  }
}

pub fn move_keys(
  doc doc: Document,
  from from: String,
  to to: String,
  keys keys_list: List(String),
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  use from_segments <- result.try(path.parse(from))
  use to_segments <- result.try(path.parse(to))
  do_move_keys(
    doc:,
    from_segments:,
    to_segments:,
    keys: keys_list,
    on_conflict:,
  )
}

fn do_move_keys(
  doc doc: Document,
  from_segments from_segments: Path,
  to_segments to_segments: Path,
  keys keys_list: List(String),
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  use idx <- index.with_index(doc)

  case index.resolve(idx, from_segments) {
    Hit(_, types.IndexTable(..))
    | Hit(_, types.IndexImplicitTable(..))
    | Hit(_, types.IndexArrayOfTablesEntry(..)) -> {
      let existing_keys =
        list.filter(keys_list, fn(key) {
          index.has_path(idx, list.append(from_segments, [KeySegment(key)]))
        })

      use <- bool.guard(existing_keys == [], return: Ok(doc))

      use doc <- result.try(structure.ensure_exists(
        doc:,
        path: path.to_string(to_segments),
        kind: types.Table,
      ))

      list.try_fold(existing_keys, doc, fn(d, key) {
        use idx2 <- index.with_index(d)
        move_single_key(
          doc: d,
          idx: idx2,
          from: from_segments,
          to: to_segments,
          key:,
          on_conflict:,
        )
      })
    }

    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(path.to_string(from_segments)),
        expected: "table",
        got: utils.index_entry_to_string(entry),
      ))

    Miss(..) | Fresh(_) -> Error(error.not_found_path(from_segments))
  }
}

pub fn merge(
  doc doc: Document,
  from from: String,
  into into: String,
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  use from_segments <- result.try(path.parse(from))
  use to_segments <- result.try(path.parse(into))
  use idx <- index.with_index(doc)

  case index.resolve(idx, from_segments) {
    // A concrete or implicit table, or an array of tables entry — all carry
    // `children` and are accepted by `do_move_keys`. Move the keys out, then
    // remove the (now empty) source. For an entry this drops the whole `[[..]]`
    // entry, shrinking the array, matching `transfer`'s "...then remove `from`".
    Hit(_, types.IndexTable(children:))
    | Hit(_, types.IndexImplicitTable(children:))
    | Hit(_, types.IndexArrayOfTablesEntry(children:, ..)) -> {
      use doc2 <- result.try(do_move_keys(
        doc:,
        from_segments:,
        to_segments:,
        keys: children,
        on_conflict:,
      ))
      use idx2 <- index.with_index(doc2)
      remove.prune(doc: doc2, idx: idx2, path: from_segments)
    }

    Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(from),
        expected: "table",
        got: utils.index_entry_to_string(entry),
      ))

    Miss(..) | Fresh(_) -> Error(error.not_found(from))
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn move_kv(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  from from: Path,
  to to: Path,
) -> Result(Document, MoltError) {
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: from)
    |> result.replace_error(error.not_found_path(from)),
  )
  let #(to_container, _) = path.split_last_segment(to)
  let to_kv_key = list.drop(to, list.length(to_container))
  let kv_node = rewrite_kv_key(kv: cursor.focus, new_key: to_kv_key)

  use tree_after_delete <- result.try(cst.delete(node: doc.tree, path: from))
  let from_key = index.path_to_index_key(from)
  let to_key = index.path_to_index_key(to)
  let idx = index.relocate_subtree(idx:, from: from_key, to: to_key)
  let doc = primitives.patch(doc:, tree: tree_after_delete, idx:)

  use idx2 <- result.try(index.get_index(doc))
  case index.resolve(idx2, to_container) {
    Hit(_, types.IndexTable(..)) | Hit(_, types.IndexArrayOfTablesEntry(..)) ->
      cst.insert_kv(
        node: doc.tree,
        into: to_container,
        kv: kv_node,
        at: cst.KvAtEnd,
      )
      |> result.map(fn(tree) { primitives.patch(doc:, tree:, idx: idx2) })

    Hit(_, types.IndexImplicitTable(..)) | Miss(..) | Fresh(_) -> {
      let full_kv = rewrite_kv_key(kv: kv_node, new_key: to)
      let new_tree = primitives.insert_kv_before_first_header(doc.tree, full_kv)
      let idx3 = index.ensure_implicit_tables(idx: idx2, path: to)
      Ok(primitives.patch(doc:, tree: new_tree, idx: idx3))
    }

    _ ->
      Error(error.InvalidOperation(
        operation: "move into inline value container",
        reason: None,
      ))
  }
}

fn move_single_key(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  from from: Path,
  to to: Path,
  key key: String,
  on_conflict on_conflict: ops.ConflictStrategy,
) -> Result(Document, MoltError) {
  let from_key_path = list.append(from, [KeySegment(key)])
  let to_key_path = list.append(to, [KeySegment(key)])
  let maybe_existing = index.get_path(index: idx, path: to_key_path)
  let exists = result.is_ok(maybe_existing)

  use <- bool.guard(
    exists && on_conflict == ops.OnConflictError,
    return: Error(error.AlreadyExists(
      path: path.to_string(to_key_path),
      current: result.unwrap(maybe_existing, IndexScalarValue(container: [])),
    )),
  )
  use <- bool.guard(
    exists && on_conflict == ops.OnConflictSkip,
    return: Ok(doc),
  )
  use doc <- result.try(case exists && on_conflict == ops.OnConflictOverwrite {
    True -> {
      use idx2 <- index.with_index(doc)
      remove.prune(doc:, idx: idx2, path: to_key_path)
    }
    False -> Ok(doc)
  })

  use idx_curr <- index.with_index(doc)
  case cst.move(node: doc.tree, from: from_key_path, to: to_key_path) {
    Ok(new_tree) -> {
      let from_ikey = index.path_to_index_key(from_key_path)
      let to_ikey = index.path_to_index_key(to_key_path)
      let idx2 =
        index.relocate_subtree(idx: idx_curr, from: from_ikey, to: to_ikey)
      Ok(primitives.patch(doc:, tree: new_tree, idx: idx2))
    }
    _ -> {
      use src_cursor <- result.try(
        query.get_cursor(node: doc.tree, path: from_key_path)
        |> result.replace_error(error.not_found_path(from_key_path)),
      )
      let val = value.from_cst(src_cursor.focus)
      use doc2 <- result.try(remove.prune(
        doc:,
        idx: idx_curr,
        path: from_key_path,
      ))
      use idx3 <- index.with_index(doc2)
      case index.resolve(idx3, to_key_path) {
        Hit(_, current) ->
          Error(error.AlreadyExists(path: path.to_string(to_key_path), current:))
        Miss(ancestor_path:, ancestor:, ..) -> {
          use site <- result.try(index.insertion_site(
            idx: idx3,
            ancestor_path:,
            ancestor:,
            full_path: to_key_path,
          ))
          primitives.write_at_site(
            doc: doc2,
            idx: idx3,
            site:,
            full_path: to_key_path,
            val:,
          )
        }
        Fresh(_) ->
          primitives.write_at_site(
            doc: doc2,
            idx: idx3,
            site: RootDottedKey(to_key_path),
            full_path: to_key_path,
            val:,
          )
      }
    }
  }
}

fn move_implicit_table(
  doc doc: Document,
  idx idx: types.DocumentIndex,
  from from: Path,
  to to: Path,
) -> Result(Document, MoltError) {
  case path.split_at_last_index(from), path.split_at_last_index(to) {
    // Neither side indexed: rewrite implicit-table headers/keys at the document
    // root, relocating the index subtree.
    Error(Nil), Error(Nil) -> {
      let from_keys = path.path_to_table_header(from)
      let to_keys = path.path_to_table_header(to)
      let new_children =
        rewrite_header_prefix(children: doc.tree.children, from_keys:, to_keys:)
      let new_tree = Node(..doc.tree, children: new_children)
      let from_key = index.path_to_index_key(from)
      let to_key = index.path_to_index_key(to)
      let idx = index.relocate_subtree(idx:, from: from_key, to: to_key)
      Ok(primitives.patch(doc:, tree: new_tree, idx:))
    }

    // Both sides indexed under the same array of tables entry (e.g. a rename
    // `srv[0].db` -> `srv[0].database`): descend into that entry and rewrite
    // within it, then rebuild.
    Ok(#(from_entry, from_rel)), Ok(#(to_entry, to_rel))
      if from_entry == to_entry
    -> {
      let from_keys = path.path_to_table_header(from_rel)
      let to_keys = path.path_to_table_header(to_rel)
      use cursor <- result.try(
        query.get_cursor(node: doc.tree, path: from_entry)
        |> result.replace_error(error.not_found_path(from)),
      )
      let entry = cursor.focus
      let new_entry =
        Node(
          ..entry,
          children: rewrite_header_prefix(
            children: entry.children,
            from_keys:,
            to_keys:,
          ),
        )
      let new_tree =
        zipper.set_focus(zipper: cursor, node: new_entry) |> zipper.unzip
      Ok(primitives.rebuild(doc:, tree: new_tree))
    }

    // Moving an implicit table across array of tables entries is not supported.
    _, _ ->
      Error(error.InvalidOperation(
        "move",
        Some(
          "cannot move an implicit table across array of tables entries: "
          <> path.to_string(from)
          <> " -> "
          <> path.to_string(to),
        ),
      ))
  }
}

/// Rewrite, within `children`, every table / array of tables header and
/// key-value whose key path begins with `from_keys`, replacing that prefix with
/// `to_keys`. Used to move/rename an implicit table.
fn rewrite_header_prefix(
  children children: List(Element(TomlKind)),
  from_keys from_keys: List(String),
  to_keys to_keys: List(String),
) -> List(Element(TomlKind)) {
  let from_len = list.length(from_keys)
  list.map(children, fn(el) {
    case el {
      N(n) if n.kind == types.Table || n.kind == types.ArrayOfTables -> {
        let tp = elements.extract_key_segments(n.children)
        use <- bool.guard(list.take(tp, from_len) != from_keys, return: el)
        let new_path = list.append(to_keys, list.drop(tp, from_len))
        N(builder.rewrite_header_path(table: n, new_path:))
      }
      N(n) if n.kind == types.KeyValue ->
        case elements.key_path(n.children) {
          Some(kp) -> {
            use <- bool.guard(list.take(kp, from_len) != from_keys, return: el)
            let new_kp = list.append(to_keys, list.drop(kp, from_len))
            let new_key = list.map(new_kp, KeySegment)
            N(rewrite_kv_key(kv: n, new_key:))
          }
          None -> el
        }
      _ -> el
    }
  })
}

fn rewrite_kv_key(
  kv kv: Node(TomlKind),
  new_key new_key: Path,
) -> Node(TomlKind) {
  let key_names =
    list.map(new_key, fn(seg) {
      case seg {
        KeySegment(name) -> name
        _ -> path.to_string([seg])
      }
    })
  let value_and_after = elements.value_tokens(kv.children)
  let new_key_elements = case key_names {
    [single] -> [T(utils.make_key_token(single))]
    _ -> [
      N(greenwood.node(types.Key, builder.build_key_tokens(key_names))),
    ]
  }
  let children =
    list.flatten([
      new_key_elements,
      [
        T(Token(kind: types.Whitespace, text: " ")),
        T(Token(kind: types.Equals, text: "")),
      ],
      value_and_after,
    ])
  Node(..kv, children:)
}
