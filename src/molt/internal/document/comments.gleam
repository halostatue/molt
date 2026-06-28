import gleam/option.{None, Some}
import gleam/result
import molt/cst
import molt/error.{type MoltError}
import molt/internal/document/index.{Fresh, Hit, Miss}
import molt/internal/path
import molt/ops
import molt/types.{type Document, Document}

pub fn set_comments(
  doc doc: Document,
  path p: String,
  comments comments: ops.Comments,
) -> Result(Document, MoltError) {
  use segments <- result.try(path.parse(p))
  // The empty path has no comment-bearing node: document-level comments (head
  // and tail) are addressed by slot, not by path. Use `set_document_comments`.
  use <- reject_empty_path(segments, "set_comments")
  use idx <- index.with_index(doc)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexImplicitTable(..)) ->
      Error(error.InvalidOperation(
        operation: "set_comments",
        reason: Some("implicit tables have no concrete node"),
      ))

    Hit(..) -> write_comments(doc:, segments:, comments:)

    Miss(..) | Fresh(_) -> Error(error.not_found(p))
  }
}

/// Reject the empty path for the path-based comment operations. Document-level
/// comments (the head and tail tombstones) are not addressable by path; they are
/// reached through `get_document_comments` / `set_document_comments`.
fn reject_empty_path(
  segments: List(types.PathSegment),
  operation: String,
  continue: fn() -> Result(b, MoltError),
) -> Result(b, MoltError) {
  case segments {
    [] ->
      Error(error.InvalidOperation(
        operation:,
        reason: Some(
          "the empty path is not a comment-bearing node; use get_document_comments / set_document_comments for document-level (head and tail) comments",
        ),
      ))
    _ -> continue()
  }
}

/// Write leading + trailing comments onto the concrete node at `segments`.
fn write_comments(
  doc doc: Document,
  segments segments: List(types.PathSegment),
  comments comments: ops.Comments,
) -> Result(Document, MoltError) {
  let ops.Comments(leading:, trailing:) = comments
  use tree1 <- result.try(cst.set_leading_comments(
    node: doc.tree,
    path: segments,
    comments: leading,
  ))
  use tree2 <- result.try(cst.set_trailing_comment(
    node: tree1,
    path: segments,
    comment: trailing,
  ))
  Ok(Document(..doc, tree: tree2))
}

pub fn get_comments(
  doc doc: Document,
  path p: String,
) -> Result(ops.Comments, MoltError) {
  use segments <- result.try(path.parse(p))
  // The empty path has no comment-bearing node: document-level comments (head
  // and tail) are addressed by slot, not by path. Use `get_document_comments`.
  use <- reject_empty_path(segments, "get_comments")
  use idx <- index.with_index(doc)
  case index.resolve(idx, segments) {
    Hit(_, types.IndexImplicitTable(..)) ->
      Error(error.InvalidOperation(
        operation: "get_comments",
        reason: Some("implicit tables have no concrete node"),
      ))

    Hit(..) -> read_comments(doc:, segments:)

    Miss(..) | Fresh(_) -> Error(error.not_found(p))
  }
}

/// Read leading + trailing comments from the node at `segments`.
fn read_comments(
  doc doc: Document,
  segments segments: List(types.PathSegment),
) -> Result(ops.Comments, MoltError) {
  use leading <- result.try(cst.leading_comments(node: doc.tree, path: segments))
  use trailing <- result.try(cst.trailing_comment(
    node: doc.tree,
    path: segments,
  ))
  Ok(ops.Comments(leading:, trailing:))
}

pub fn move_comments(
  doc doc: Document,
  from from: String,
  to to: String,
) -> Result(Document, MoltError) {
  use from_segments <- result.try(path.parse(from))
  use to_segments <- result.try(path.parse(to))
  // Document-level comments are addressed by slot, not by path: `move_comments`
  // operates between concrete nodes only. Neither endpoint may be the empty
  // path.
  use <- reject_empty_path(from_segments, "move_comments")
  use <- reject_empty_path(to_segments, "move_comments")
  use idx <- index.with_index(doc)
  use _ <- result.try(ensure_comment_source(
    idx:,
    segments: from_segments,
    raw: from,
  ))

  use from_leading <- result.try(cst.leading_comments(
    node: doc.tree,
    path: from_segments,
  ))
  use from_trailing <- result.try(cst.trailing_comment(
    node: doc.tree,
    path: from_segments,
  ))
  case from_leading, from_trailing {
    [], None -> Ok(doc)
    _, _ -> {
      use tree1 <- result.try(
        cst.set_leading_comments(
          node: doc.tree,
          path: from_segments,
          comments: [],
        ),
      )
      use tree2 <- result.try(cst.set_trailing_comment(
        node: tree1,
        path: from_segments,
        comment: None,
      ))
      let doc2 = Document(..doc, tree: tree2)
      use tree3 <- result.try(cst.set_leading_comments(
        node: doc2.tree,
        path: to_segments,
        comments: from_leading,
      ))
      use tree4 <- result.try(cst.set_trailing_comment(
        node: tree3,
        path: to_segments,
        comment: from_trailing,
      ))
      Ok(Document(..doc2, tree: tree4))
    }
  }
}

/// A comment move's source must be a concrete node (the empty path is already
/// rejected upstream). Implicit tables have no node to carry comments.
fn ensure_comment_source(
  idx idx: types.DocumentIndex,
  segments segments: List(types.PathSegment),
  raw raw: String,
) -> Result(Nil, MoltError) {
  case index.resolve(idx, segments) {
    Hit(_, types.IndexImplicitTable(..)) ->
      Error(error.InvalidOperation(
        operation: "move_comments",
        reason: Some("implicit tables have no concrete node carrying comments"),
      ))
    Hit(..) -> Ok(Nil)
    Miss(..) | Fresh(_) -> Error(error.not_found(raw))
  }
}
