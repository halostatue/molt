//// Acceptance test for the "Coercing Non-TOML Input" example in
//// `guides-claude/repair.md`. The code here is the source of truth for
//// that example — keep them in sync.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import greenwood.{type Element, type Node, NodeElement, Token, TokenElement}
import molt
import molt/cst
import molt/types.{type TomlKind}
import molt/value

pub fn yaml_coercion_test() {
  let source = "---\ndatabase:\n  host: localhost\n  port: 5432\n"

  let assert Ok(out) = yaml_to_toml(source)

  // The `---` separator is dropped; `database:` becomes a table header and the
  // indented entries become its keys (valid TOML, re-validated inside).
  assert string.contains(out, "[database]")
  assert string.contains(out, "host = \"localhost\"")
  assert string.contains(out, "port = \"5432\"")
}

fn yaml_to_toml(source: String) -> Result(String, Nil) {
  let assert Ok(doc) = molt.parse(source)

  // Every line came back as a root-level Error node, so map over the root's
  // children: replace each with a valid node, or drop it.
  let tree = cst.from_document(doc)
  let repaired =
    greenwood.Node(..tree, children: list.filter_map(tree.children, repair))

  let fixed = cst.to_document(repaired)

  case molt.document_errors(fixed) {
    [] -> Ok(molt.to_string(fixed))
    _ -> Error(Nil)
  }
}

fn repair(el: Element(TomlKind)) -> Result(Element(TomlKind), Nil) {
  case el {
    NodeElement(node) if node.kind == types.Error ->
      case node.children {
        [NodeElement(inner)] if inner.kind == types.KeyValue ->
          interpret_tokens(inner.children)
          |> option.map(NodeElement)
          |> option.to_result(Nil)
        _ -> Error(Nil)
      }
    _ -> Ok(el)
  }
}

fn interpret_tokens(
  children: List(Element(TomlKind)),
) -> Option(Node(TomlKind)) {
  case meaningful_texts(children) {
    // "---" YAML document separator — drop it.
    ["---", ..] -> None

    // "key:" on its own → a YAML mapping header → a TOML table header.
    [key] ->
      strip_colon(key) |> option.map(fn(name) { cst.build_table([name]) })

    // "key: value" → a TOML key/value pair.
    [key, value, ..] ->
      strip_colon(key) |> option.map(fn(name) { make_kv_node(name, value) })

    _ -> None
  }
}

fn meaningful_texts(children: List(Element(TomlKind))) -> List(String) {
  list.filter_map(children, fn(el) {
    case el {
      TokenElement(Token(kind: types.Whitespace, ..)) -> Error(Nil)
      TokenElement(Token(kind: types.Newline, ..)) -> Error(Nil)
      TokenElement(Token(text:, ..)) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn strip_colon(key: String) -> Option(String) {
  case string.ends_with(key, ":") {
    True -> Some(string.drop_end(key, 1))
    False -> None
  }
}

fn make_kv_node(key: String, val: String) -> Node(TomlKind) {
  cst.build_kv(key:, value: value.to_cst(value.string(val)))
}
