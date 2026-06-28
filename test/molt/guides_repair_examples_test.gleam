//// Acceptance tests for the code examples in `guides/repair.md`. Each test
//// mirrors a recipe from the guide so the documented code is known to compile
//// and produce the claimed result.

import gleam/list
import gleam/result
import greenwood.{type Node, NodeElement}
import molt
import molt/cst
import molt/types.{type TomlKind, KeySegment}
import molt/value

// Recipe: "Duplicate keys and tables"
pub fn duplicate_key_recipe_test() {
  assert Ok("a = 1\n")
    == tree_of("a = 1\na = 2\n")
    |> cst.delete_where(path: [KeySegment("a")], where: fn(n) {
      cst.value_text(n) == "2"
    })
    |> result.map(emit)
}

// Recipe: "A value that won't parse"
pub fn bad_value_recipe_test() {
  assert Ok("port = 5432\n")
    == tree_of("port = flase\n")
    |> cst.update(path: [KeySegment("port")], with: fn(kv) {
      let assert Ok(fixed) =
        cst.set_kv_value(kv:, value: value.to_cst(value.int(5432)))
      fixed
    })
    |> result.map(emit)
}

// Recipe: "A value that won't parse" — structural array rebuild
pub fn misplaced_separator_recipe_test() {
  assert Ok("a = [1, 2]\n")
    == tree_of("a = [1,, 2]\n")
    |> cst.update(path: [KeySegment("a")], with: fn(kv) {
      let assert Ok(fixed) =
        cst.set_kv_value(
          kv:,
          value: value.to_cst(value.array([value.int(1), value.int(2)])),
        )
      fixed
    })
    |> result.map(emit)
}

// Recipe: "A key that collides with an ancestor"
pub fn key_collision_recipe_test() {
  assert Ok("[a.b]\n")
    == tree_of("a = 1\n[a.b]\n")
    |> cst.delete(path: [KeySegment("a")])
    |> result.map(emit)
}

// Recipe: "A broken table header" — salvage the body onto a fresh header
pub fn broken_table_header_recipe_test() {
  let tree = tree_of("[settings\nverbose = true\ntimeout = 30\n")

  let assert Ok(bad) = cst.get(tree, path: [KeySegment("settings")])

  let body =
    list.filter(bad.children, fn(el) {
      case el {
        NodeElement(n) -> n.kind == types.KeyValue
        _ -> False
      }
    })

  let fixed =
    list.fold(body, cst.build_table(path: ["settings"]), fn(table, kv) {
      greenwood.append_child(in: table, child: kv)
    })

  let assert Ok(tree) =
    cst.replace(tree, path: [KeySegment("settings")], new: fixed)

  assert "[settings]\nverbose = true\ntimeout = 30\n" == emit(tree)
}

// Recipe: "Renaming or replacing a key"
pub fn rename_key_recipe_test() {
  assert Ok("[settings]\nnew_key = 1\n")
    == tree_of("[settings]\nold_key = 1\n")
    |> cst.rename(
      path: [KeySegment("settings"), KeySegment("old_key")],
      to: "new_key",
    )
    |> result.map(emit)
}

fn tree_of(source: String) -> Node(TomlKind) {
  let assert Ok(tree) = molt.parse(source) |> result.map(cst.from_document)
  tree
}

fn emit(tree: Node(TomlKind)) -> String {
  let doc = cst.to_document(tree)
  assert molt.document_errors(doc) == []
  molt.to_string(doc)
}
