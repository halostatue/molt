//// Representation-only conversions between inline and block surface forms.
////
//// `set_representation(doc, path, form)` toggles how a table / array of tables
//// is written, never what it holds. Conversions run on the TOML 1.1 CST and
//// preserve comment / multiline trivia (lossless); 1.0 lossiness is purely an
//// emit-time concern handled by the existing 1.1→1.0 downgrade.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import greenwood.{type Node, Node, NodeElement as N}
import molt/cst
import molt/error.{type MoltError}
import molt/internal/cst/builder
import molt/internal/cst/elements
import molt/internal/cst/query
import molt/internal/document/index.{Fresh, Hit, Miss}
import molt/internal/document/primitives
import molt/internal/document/remove
import molt/internal/path
import molt/internal/utils
import molt/internal/validate
import molt/ops
import molt/types.{type Document, type Path, IndexSegment, KeySegment}

pub fn set_representation(
  doc doc: Document,
  path p: String,
  form form: ops.Form,
) -> Result(Document, MoltError) {
  use segments <- result.try(path.parse(p))
  use converted <- result.try(convert(doc:, path: p, segments:, form:))
  // Validate-after: the conversions hand-assemble InlineTable / Array /
  // ArrayOfTables nodes. Refuse rather than emit a tree that fails validation:
  // e.g. converting a `[a]` section that has descendant sub-tables (`[a.b]`) to
  // inline form is illegal TOML and has no lossless inline representation.
  case validate.count(converted.tree) {
    0 -> Ok(converted)
    _ ->
      Error(error.InvalidOperation(
        "representation",
        Some("conversion would produce invalid TOML at \"" <> p <> "\""),
      ))
  }
}

fn convert(
  doc doc: Document,
  path p: String,
  segments segments: Path,
  form form: ops.Form,
) -> Result(Document, MoltError) {
  use idx <- index.with_index(doc)
  case form, index.resolve(idx, segments) {
    // --- Block form ---------------------------------------------------------
    // An inline table becomes a `[path]` section.
    ops.Block, Hit(_, types.IndexInlineTableValue(..)) ->
      inline_table_to_block(doc:, path: segments)

    // Already block: no-op.
    ops.Block, Hit(_, types.IndexTable(..)) -> Ok(doc)
    ops.Block, Hit(_, types.IndexArrayOfTables(..)) -> Ok(doc)

    // An array of inline tables becomes `[[path]]` entries.
    ops.Block, Hit(_, types.IndexArrayValue(..)) ->
      inline_array_to_block_aot(doc:, path: segments)

    // --- Inline form --------------------------------------------------------
    // A `[path]` section becomes `path = { … }`.
    ops.Inline, Hit(_, types.IndexTable(..)) ->
      block_table_to_inline(doc:, path: segments)

    ops.Inline, Hit(_, types.IndexArrayOfTables(count:, ..)) ->
      aot_to_inline_array(doc:, path: segments, count:)

    // Already inline: no-op.
    ops.Inline, Hit(_, types.IndexInlineTableValue(..)) -> Ok(doc)

    // Anything else at the path is not a convertible structure.
    _, Hit(_, entry) ->
      Error(error.TypeMismatch(
        path: Some(p),
        expected: "inline or block table / array of tables",
        got: utils.index_entry_to_string(entry),
      ))

    _, Miss(..) | _, Fresh(_) -> Error(error.not_found(p))
  }
}

/// `[0, 1, …, n-1]`.
fn indices_up_to(n: Int) -> List(Int) {
  do_indices(n - 1, [])
}

fn do_indices(i: Int, acc: List(Int)) -> List(Int) {
  use <- bool.guard(i < 0, acc)
  do_indices(i - 1, [i, ..acc])
}

/// `a = { … }` -> `[a]\n…`. Extracts the inline entries, prunes the inline KV,
/// emits a `[path]` header, and re-inserts each entry in section form.
fn inline_table_to_block(
  doc doc: Document,
  path segments: Path,
) -> Result(Document, MoltError) {
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: segments)
    |> result.replace_error(error.not_found_path(segments)),
  )
  use inline_table <- result.try(
    primitives.find_kv_value(cursor.focus, types.InlineTable)
    |> result.replace_error(error.TypeMismatch(
      path: Some(path.to_string(segments)),
      expected: "inline table",
      got: utils.toml_kind(cursor.focus.kind),
    )),
  )
  let section_kvs =
    elements.extract_inline_entries(inline_table)
    |> list.map(elements.kv_to_section_form)
  // Comments on the inline KV (`# … \n squall = { … }`) must survive onto the
  // new `[path]` header, not be discarded with the pruned KV.
  use leading <- result.try(cst.leading_comments(node: doc.tree, path: segments))
  use trailing <- result.try(cst.trailing_comment(
    node: doc.tree,
    path: segments,
  ))
  use idx <- index.with_index(doc)
  use doc2 <- result.try(remove.prune(doc:, idx:, path: segments))
  let key_only = path.path_to_table_header(segments)
  let header = builder.build_empty_table(key_only)
  use with_header <- result.try(cst.insert_table_node(
    node: doc2.tree,
    table: header,
  ))
  let section_cst_path = list.map(key_only, KeySegment)
  use filled <- result.try(
    list.try_fold(section_kvs, with_header, fn(tree, kv) {
      cst.insert_kv(node: tree, into: section_cst_path, kv:, at: cst.KvAtEnd)
    }),
  )
  use new_tree <- result.try(set_comments_if_any(
    tree: filled,
    segments:,
    leading:,
    trailing:,
  ))
  Ok(primitives.rebuild(doc: doc2, tree: new_tree))
}

/// Re-apply `leading` / `trailing` comments captured from a source node onto
/// the node now at `segments` after a representation conversion. No-ops for the
/// empty cases, so a freshly built node's own (blank-line / whitespace) trivia
/// is left intact when there is nothing to carry over.
fn set_comments_if_any(
  tree tree: Node(types.TomlKind),
  segments segments: Path,
  leading leading: List(String),
  trailing trailing: Option(String),
) -> Result(Node(types.TomlKind), MoltError) {
  use with_leading <- result.try(case leading {
    [] -> Ok(tree)
    _ -> cst.set_leading_comments(node: tree, path: segments, comments: leading)
  })
  case trailing {
    None -> Ok(with_leading)
    Some(_) ->
      cst.set_trailing_comment(
        node: with_leading,
        path: segments,
        comment: trailing,
      )
  }
}

/// Capture the leading + trailing comments at every `path ++ [i]` for
/// `i` in `0..count-1` (one per array element / AoT entry).
fn capture_entry_comments(
  tree tree: Node(types.TomlKind),
  segments segments: Path,
  count count: Int,
) -> Result(List(#(List(String), Option(String))), MoltError) {
  list.try_map(indices_up_to(count), fn(i) {
    let entry_path = list.append(segments, [IndexSegment(i)])
    use leading <- result.try(cst.leading_comments(node: tree, path: entry_path))
    use trailing <- result.try(cst.trailing_comment(
      node: tree,
      path: entry_path,
    ))
    Ok(#(leading, trailing))
  })
}

/// `[a]\n…` -> `a = { … }`. Gathers the section's KV children, assembles an
/// inline table, deletes the section, and inserts the new inline KV into the
/// section's parent scope (root for a top-level section). A root-level inline KV
/// is placed before any section headers, so converting a section that sits
/// after other sections moves it to the top: the only valid placement.
fn block_table_to_inline(
  doc doc: Document,
  path segments: Path,
) -> Result(Document, MoltError) {
  use table_node <- result.try(cst.get(node: doc.tree, path: segments))
  let kvs = elements.get_kv_children(table_node.children)
  let inline = elements.section_kvs_to_inline_table(kvs)
  let #(parent, last) = path.split_last_segment(segments)
  let key = case last {
    KeySegment(k) -> k
    IndexSegment(_) -> ""
  }
  // Carry the `[path]` header's own trivia (leading and trailing comments),
  // except its leading blank line(s) onto the inlined key.
  let base_kv = builder.build_kv_node(key:, value: N(inline))
  let kv =
    Node(..base_kv, trivia: table_node.trivia)
    |> builder.drop_leading_newlines
  use deleted <- result.try(cst.delete(node: doc.tree, path: segments))
  use new_tree <- result.try(cst.insert_kv(
    node: deleted,
    into: parent,
    kv:,
    at: cst.KvAtEnd,
  ))
  Ok(primitives.rebuild(doc:, tree: new_tree))
}

/// `a = [ { … }, … ]` -> `[[a]]` entries. Every array element must be an inline
/// table; anything else (scalar / nested array / mixed) is a TypeMismatch. The
/// inline KV is deleted and one `[[a]]` entry is emitted per element.
fn inline_array_to_block_aot(
  doc doc: Document,
  path segments: Path,
) -> Result(Document, MoltError) {
  use cursor <- result.try(
    query.get_cursor(node: doc.tree, path: segments)
    |> result.replace_error(error.not_found_path(segments)),
  )
  use array_node <- result.try(
    primitives.find_kv_value(cursor.focus, types.Array)
    |> result.replace_error(type_mismatch(segments, "array")),
  )
  use inline_tables <- result.try(
    list.try_map(elements.extract_array_items(array_node), fn(elem) {
      element_inline_table(elem)
      |> result.replace_error(type_mismatch(segments, "array of inline tables"))
    }),
  )
  // Capture comments before mutation: the whole `a = [ … ]` KV plus each array
  // element. The KV comment leads the first `[[a]]`; each element comment leads
  // its own `[[a]]`.
  use whole_leading <- result.try(cst.leading_comments(
    node: doc.tree,
    path: segments,
  ))
  use whole_trailing <- result.try(cst.trailing_comment(
    node: doc.tree,
    path: segments,
  ))
  let count = list.length(inline_tables)
  use element_comments <- result.try(capture_entry_comments(
    tree: doc.tree,
    segments:,
    count:,
  ))
  let key_only = path.path_to_table_header(segments)
  let entries =
    list.map(inline_tables, fn(it) { build_aot_entry_from_inline(key_only, it) })
  use deleted <- result.try(cst.delete(node: doc.tree, path: segments))
  use inserted <- result.try(
    list.try_fold(entries, deleted, fn(tree, entry) {
      cst.insert_table_node(node: tree, table: entry)
    }),
  )
  use new_tree <- result.try(
    list.try_fold(
      list.index_map(element_comments, fn(c, i) { #(i, c) }),
      inserted,
      fn(tree, indexed) {
        let #(i, #(elem_leading, elem_trailing)) = indexed
        // The first entry also inherits the KV-level comments.
        let leading = case i {
          0 -> list.append(whole_leading, elem_leading)
          _ -> elem_leading
        }
        let trailing = case i, elem_trailing {
          0, None -> whole_trailing
          _, t -> t
        }
        set_comments_if_any(
          tree:,
          segments: list.append(segments, [IndexSegment(i)]),
          leading:,
          trailing:,
        )
      },
    ),
  )
  Ok(primitives.rebuild(doc:, tree: new_tree))
}

/// Find the InlineTable node inside an ArrayElement, if any.
fn element_inline_table(
  elem: Node(types.TomlKind),
) -> Result(Node(types.TomlKind), Nil) {
  list.find_map(elem.children, fn(child) {
    case child {
      N(n) if n.kind == types.InlineTable -> Ok(n)
      _ -> Error(Nil)
    }
  })
}

/// Build a `[[key]]` entry node whose body is the inline table's entries in
/// section form.
fn build_aot_entry_from_inline(
  key_only: List(String),
  inline_table: Node(types.TomlKind),
) -> Node(types.TomlKind) {
  let section_kvs =
    elements.extract_inline_entries(inline_table)
    |> list.map(elements.kv_to_section_form)
  let base = builder.build_empty_array_of_tables(key_only)
  Node(..base, children: list.append(base.children, list.map(section_kvs, N)))
}

/// `[[a]]` entries -> `a = [ { … }, … ]`. Each entry's body becomes an inline
/// table; the entries are deleted and replaced by a single array-valued inline
/// KV in the family's parent scope.
fn aot_to_inline_array(
  doc doc: Document,
  path segments: Path,
  count count: Int,
) -> Result(Document, MoltError) {
  let indices = indices_up_to(count)
  use inline_tables <- result.try(
    list.try_map(indices, fn(i) {
      let entry_path = list.append(segments, [IndexSegment(i)])
      use entry <- result.try(cst.get(node: doc.tree, path: entry_path))
      let kvs = elements.get_kv_children(entry.children)
      Ok(elements.section_kvs_to_inline_table(kvs))
    }),
  )
  // Capture each `[[a]]` entry's comments before deletion. If any entry carries
  // a comment, the array is rendered multiline so every comment keeps a line of
  // its own; a comment-free family collapses to a single-line array.
  use entry_comments <- result.try(capture_entry_comments(
    tree: doc.tree,
    segments:,
    count:,
  ))
  let array_node = case list.any(entry_comments, has_comment) {
    False -> elements.inline_tables_to_array(inline_tables)
    True ->
      elements.inline_tables_to_multiline_array(inline_tables, entry_comments)
  }
  let #(parent, last) = path.split_last_segment(segments)
  let key = case last {
    KeySegment(k) -> k
    IndexSegment(_) -> ""
  }
  let kv = builder.build_kv_node(key:, value: N(array_node))
  // Delete entries high-index-first so earlier indices stay valid.
  use deleted <- result.try(
    list.try_fold(list.reverse(indices), doc.tree, fn(tree, i) {
      cst.delete(node: tree, path: list.append(segments, [IndexSegment(i)]))
    }),
  )
  use new_tree <- result.try(cst.insert_kv(
    node: deleted,
    into: parent,
    kv:,
    at: cst.KvAtEnd,
  ))
  Ok(primitives.rebuild(doc:, tree: new_tree))
}

fn has_comment(comments: #(List(String), Option(String))) -> Bool {
  let #(leading, trailing) = comments
  leading != [] || trailing != None
}

fn type_mismatch(segments: Path, expected: String) -> MoltError {
  error.TypeMismatch(
    path: Some(path.to_string(segments)),
    expected:,
    got: "value",
  )
}
