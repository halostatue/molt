# Repairing Invalid TOML with `molt/cst`

`molt.parse` is forgiving: it almost always returns a tree, even for TOML that
breaks the rules. Whether the document has duplicate keys, value collisions, or
unparsable values, the document returns as `Ok(doc)` but records how many
problems it found in `doc.error_count`.

The higher-level operations in `molt` refuse to touch a broken document (they
need a logical representation that cannot be built) and return
`InvalidDocument`. The syntax tree is intact and editable with `molt/cst`, which
operates directly on concrete tree nodes. This guide shows how to read the
errors, fix the tree, and validate the result.

If `molt.has_errors(doc)` is `False`, you don't need any of this. Use the `molt`
API directly.

## The Repair Loop {#the-repair-loop}

Every repair follows the same shape:

1. **Parse** the document with `molt.parse`. It returns `Error(ParseError(..))`
   or `Error(InvalidSourceEncoding)` when the source can't be tokenized, but
   otherwise returns `Ok(doc)` with a non-zero `doc.error_count`.
2. **Inspect** `molt.document_errors(doc)` to learn what's wrong and where.
3. **Get the tree** with `cst.from_document(doc)`.
4. **Edit** the offending nodes with `molt/cst` functions.
5. **Rebuild and validate**: `cst.to_document(tree)` (which re-validates).
6. **Check** `molt.document_errors(doc) == []`, then emit with `molt.to_string`.

```gleam
import molt
import molt/cst
import molt/types.{type SyntaxError, KeySegment}

pub fn repair(source: String) -> Result(String, List(SyntaxError)) {
  let assert Ok(doc) = molt.parse(source)

  let fixed =
    cst.from_document(doc)
    |> apply_fixes(molt.document_errors(doc)) // your repair logic, see recipes below
    |> cst.to_document

  case molt.document_errors(fixed) {
    [] -> Ok(molt.to_string(fixed))
    remaining -> Error(remaining)
  }
}
```

`cst.to_document` performs validation on the modified document.

## Reading the Errors {#reading-errors}

`molt.document_errors(doc)` returns a `List(types.SyntaxError)`. Each is
`SyntaxError(kind:, path:, span:)`, where `kind` is a `SyntaxErrorKind`, `path`
locates the enclosing scope, and `span` points at the offending instance. When a
`kind` carries an `original` span, that span points at the _first_ definition
(useful for telling an original apart from its duplicate).

```gleam
import gleam/bool
import molt/types

let errors = molt.document_errors(doc)
use <- bool.guard(errors == [], return: Nil) // clean

list.each(errors, fn(e) {
  case e.kind {
    types.DuplicateKey(key:, ..) -> report_duplicate(key, e.span)
    types.BadValue(text:) -> report_bad_value(text, e.span)
    types.KeyIsScalar(key:, ..) -> report_conflict(key, e.span)
    _ -> report_other(e)
  }
})
```

## What Can Be Repaired {#what-can-be-repaired}

`types.SyntaxErrorKind` organises its variants into four categories by _nature_:
path duplicates, path-traversal conflicts, structural syntax errors, and other
unparsable content. Repair cares about a different axis: did enough of the
document survive as addressable nodes, and is the correct fix unambiguous? This
guide regroups the same variants by recoverability.

### CST-recoverable {#cst-recoverable}

> The node is real and the fix is unambiguous.

| Variant                                                                                     | Repair                                                                                                                                                         |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BadValue`                                                                                  | The `InvalidValue` token holds the raw text; replace it with a valid value ([recipe](#a-value-that-wont-parse)).                                               |
| `DuplicateKey`, `DuplicateTable`, `DuplicateKeyInInlineTable`                               | Both definitions are nodes; delete the duplicate ([recipe](#duplicate-keys-and-tables)).                                                                       |
| `InvalidKeySyntax`                                                                          | The key node exists with an `InvalidValue` child; rename it ([recipe](#renaming-or-replacing-a-key)).                                                          |
| `KeyIsScalar`, `KeyIsInlineTable`, `KeyIsArray`                                             | Remove the conflicting ancestor or descendant ([recipe](#a-key-that-collides-with-an-ancestor)).                                                               |
| `MalformedTableHeader`, `EmptyTableHeader`                                                  | The header node exists; repair or remove it ([recipe](#a-broken-table-header)).                                                                                |
| `MisplacedArraySeparator`, `MisplacedInlineTableSeparator`, `InvalidBareValueInInlineTable` | The container node exists; rebuild the value or reposition the stray tokens ([recipe](#a-value-that-wont-parse)). Often secondary to an `Unterminated*` error. |
| `MissingValue`, `ExtraEquals`, `MultipleValues`                                             | The `KeyValue` node is intact; set the intended value ([recipe](#a-value-that-wont-parse)).                                                                    |

### Partially recoverable {#partially-recoverable}

> The node is real but the fix is ambiguous.

| Variant              | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `UnterminatedString` | A single-line string left open, e.g. `s = "foo`. The node is real, so a CST edit can inject the closing quote…but _where_ to close is ambiguous when a `#` follows. In `url = "https://host/page#anchor`, the `#` is string content; in `s = "foo # note`, it may be an intended comment. Closing at end-of-line keeps everything as string content; closing before the `#` can drop a real anchor or swallow text. Safe only when you can infer intent. |
| `UnparsableContent`  | An `Error` node exists and can be removed or replaced; surrounding structure is intact, but the original intent may be unclear.                                                                                                                                                                                                                                                                                                                          |

### Needs a manual source fix {#needs-a-manual-source-fix}

> The rest of the document is gone.

These variants indicate that the parser swallowed everything after the error, so
subsequent lines are misclassified rather than parsed into addressable nodes.
Surface them to the user; don't try to auto-repair.

| Variant                       | Why                                                                                                        |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `NoValidTomlStructure`        | No recognisable TOML at all. Only `Error` nodes and trivia exist.                                          |
| `UnterminatedArray`           | Everything after `[` is consumed as array content; headers become `BadValue`. No safe place to inject `]`. |
| `UnterminatedInlineTable`     | Subsequent lines are consumed as inline-table entries.                                                     |
| `UnterminatedMultilineString` | All source after the opening `"""`/`'''` is buried inside the token's text, not as nodes.                  |

Detecting the unrecoverable cases is a `kind` match:

```gleam
fn needs_manual_fix(e: SyntaxError) -> Bool {
  case e.kind {
    types.UnterminatedArray
    | types.UnterminatedInlineTable
    | types.UnterminatedMultilineString
    | types.NoValidTomlStructure -> True
    _ -> False
  }
}
```

## Recipes {#recipes}

The path-addressed `cst` functions (`delete`, `replace`, `update`, and their
`_where` variants) are all you need for the common cases. The `_where` variants
take a predicate function over the candidate node allowing disambiguation of
confusing nodes, which is exactly the situation a duplicate creates.
`cst.value_text` returns a node's raw value text (with quotes for strings:
`"'localhost'"`, `"2"`), which often makes a convenient predicate.

### Duplicate keys and tables {#duplicate-keys-and-tables}

```toml
a = 1
a = 2
```

This parses fine but is invalid TOML. Both assignments are real nodes at the
same path, so disambiguate by value and delete the one you don't want:

```gleam
let assert Ok(tree) = molt.parse("a = 1\na = 2\n") |> result.map(cst.from_document)

let assert Ok(tree) =
  cst.delete_where(tree, path: [KeySegment("a")], where: fn(n) {
    cst.value_text(n) == "2"
  })
// -> a = 1
```

To keep the duplicate's value instead of deleting it, `cst.update_where` the
survivor and delete the other, or merge as appropriate. The same approach works
for `DuplicateTable`: locate by a distinguishing child and `cst.delete` the
redundant header.

### A value that won't parse {#a-value-that-wont-parse}

```toml
port = flase
```

For `BadValue`, `MissingValue`, `ExtraEquals`, or `MultipleValues`, the
`KeyValue` node is intact, but its value is wrong. Swap in a correctly-typed
value with `cst.update` and `cst.set_kv_value`. The replacement is a CST element
built from a `value.Value` with `value.to_cst`, so it carries the right token or
node kind (integer, string, array, …), and the node's key, whitespace, and
comments are preserved:

```gleam
import molt/value

let assert Ok(tree) =
  cst.update(tree, path: [KeySegment("port")], with: fn(kv) {
    let assert Ok(fixed) = cst.set_kv_value(kv:, value: value.to_cst(value.int(5432)))
    fixed
  })
// -> port = 5432
```

Any value type works the same way:

```gleam
value.to_cst(value.string("localhost"))
value.to_cst(value.array([value.string("THX"), value.int(1187), ]))
// and so on
```

A structurally broken array or inline table (misplaced commas,
`MisplacedArraySeparator` / `MisplacedInlineTableSeparator`) or a bare
inline-table entry (`InvalidBareValueInInlineTable`) can be fixed the same way:
rebuild the value wholesale rather than splicing the stray tokens. To preserve
an exact source spelling (underscores, hex casing), build the value with
`value.parse_value` instead of a constructor.

If you also need to change the key, replace the whole pair with a freshly built
node. Note that `build_kv` mints a fresh node and drops the original's comments:

```gleam
let new_kv = cst.build_kv(key: "host", value: value.to_cst(value.string("localhost")))
let assert Ok(tree) = cst.replace(tree, path: [KeySegment("broken")], new: new_kv)
```

### A key that collides with an ancestor {#a-key-that-collides-with-an-ancestor}

```toml
a = 1
[a.b]
```

This results in `KeyIsScalar(key: "b", ..)` because the header tries to descend
through the scalar `a`. You must choose which definition survives: molt can't
guess. Drop the scalar so the table can stand:

```gleam
let assert Ok(tree) = cst.delete(tree, path: [KeySegment("a")])
```

…or drop the conflicting descendant instead. `KeyIsArray` and `KeyIsInlineTable`
work the same way; the error's `original` span locates the ancestor.

### A broken table header {#a-broken-table-header}

```toml
[settings
verbose = true
timeout = 30
```

`MalformedTableHeader` (mismatched brackets, junk after `]`, …) and
`EmptyTableHeader` (`[]`) only break the _header_. The body survives: in molt's
CST the key/value pairs are children of the `Table` node, so deleting the table
throws its values away too. Salvage the body onto a fresh header instead.

```gleam
import gleam/list
import greenwood.{NodeElement}

// Addressable as long as the header's key tokens survived parsing.
let assert Ok(bad) = cst.get(tree, path: [KeySegment("settings")])

// The body key/value nodes. Each keeps its own comments and formatting.
let body =
  list.filter(bad.children, fn(el) {
    case el {
      NodeElement(n) -> n.kind == types.KeyValue
      _ -> False
    }
  })

// Build a clean header and re-attach the salvaged body, unchanged.
let fixed =
  list.fold(body, cst.build_table(path: ["settings"]), fn(table, kv) {
    greenwood.append_child(in: table, child: kv)
  })

let assert Ok(tree) = cst.replace(tree, path: [KeySegment("settings")], new: fixed)
```

> If the header is too mangled to address by path (its key tokens are themselves
> invalid), locate the `Table` node positionally with `cst.zipper_where` and a
> predicate over `node.children`, then apply the same salvage. To discard the
> table and its body together, use `cst.delete`.

### Renaming or replacing a key {#renaming-or-replacing-a-key}

`cst.rename` rewrites the last segment of a path (on both keys and table
headers), so it's the tool for `InvalidKeySyntax` when you want to substitute a
valid name for a malformed one:

```gleam
let assert Ok(tree) =
  cst.rename(tree, path: [KeySegment("settings"), KeySegment("old_key")], to: "new_key")
```

The new name is quoted automatically if it isn't bare-safe.

> If the broken key can't be addressed by name (the parser couldn't read it as a
> key at all), locate its `KeyValue` node positionally first, using
> `cst.zipper_where` or `cst.update_where` and a predicate. You can then rename
> it or rebuild the pair with `cst.build_kv`.

## When a Path Isn't Enough: the Zipper {#when-a-path-isnt-enough-the-zipper}

The functions above edit one node at a known path. Sometimes that's not enough
because you need to walk among siblings, move up or down _relative_ to a node
you found, make several local edits while holding your place, or reach a node
you can't name cleanly (a malformed key, one of a pair of duplicates). Molt
provides the answer: a **cursor**.

A cursor is a [greenwood zipper][gz]: a focus on one node plus the context
needed to rebuild the whole tree around it. `cst.zipper_at` and
`cst.zipper_where` are path-aware wrappers over `greenwood/zipper` that locate a
node and return a cursor already focused on the located node:

```gleam
import greenwood/zipper

// Focus on the `a` whose value is `2`, disambiguating the duplicate.
let assert Ok(cursor) =
  cst.zipper_where(tree, path: [KeySegment("a")], where: fn(n) {
    cst.value_text(n) == "2"
  })
```

From the cursor you navigate and edit with `greenwood/zipper`, then `unzip` to
rebuild the tree:

| Function                                         | Use                                    |
| ------------------------------------------------ | -------------------------------------- |
| `zipper.down` / `up` / `left` / `right`          | move the focus                         |
| `zipper.set_focus` / `map_focus`                 | replace or transform the focused node  |
| `zipper.insert_left` / `insert_right` / `delete` | restructure around the focus           |
| `zipper.unzip`                                   | rebuild the whole tree from the cursor |

```gleam
let tree =
  cursor
  |> zipper.set_focus(node: new_node)
  |> zipper.unzip
```

Most of the `cst` functions use the cursor internally, but this provides an
escape hatch for more advanced editing.

## Builder API {#builder-api}

`molt/cst` exposes builders for constructing valid nodes to insert or replace:

| Function                            | Produces                                           |
| ----------------------------------- | -------------------------------------------------- |
| `cst.build_kv(key:, value:)`        | `key = value\n` node                               |
| `cst.build_inline_kv(key:, value:)` | `key = value` node (no newline, for inline tables) |
| `cst.build_table(path:)`            | `[path.to.table]\n` header node                    |
| `cst.build_array_of_tables(path:)`  | `[[path.to.table]]\n` header node                  |

Values come from `value.to_cst(value.string("..."))` (or any other `value.*`
constructor). Keys are auto-quoted when they contain characters that aren't
valid in bare keys.

## Comment Functions {#comment-functions}

Repairs often want to preserve or adjust comments. `molt/cst` reads and writes
them directly on the node at a path:

| Function                                         | Effect                                             |
| ------------------------------------------------ | -------------------------------------------------- |
| `cst.leading_comments(node, path)`               | Get the leading comment lines (`List(String)`).    |
| `cst.set_leading_comments(node, path, comments)` | Replace the leading comments.                      |
| `cst.trailing_comment(node, path)`               | Get the inline comment, if any (`Option(String)`). |
| `cst.set_trailing_comment(node, path, comment)`  | Set or clear the inline comment (`None` clears).   |
| `cst.strip_all_comments(node)`                   | Recursively remove every comment in the tree.      |

Mostly reach for these when building fresh nodes (`cst.build_*`,
`value.to_cst`), which carry no comments.

## A Second Example: Coercing Non-TOML Input {#a-second-example-coercing-non-toml-input}

The recipes above repair _broken TOML_, where the structure is mostly right. The
same primitives go further: they can rewrite a tree built from text that isn't
TOML at all, for one-shot conversions from a near-TOML format.

Take a trivial YAML document:

```yaml
---
database:
  host: localhost
  port: 5432
```

`molt.parse` recognises none of these lines. Each becomes a root-level Error
node wrapping the parser's best-effort guess:
`Node(Error, [NodeElement(Node(KeyValue, ...))])`.

Every broken line sits at the root, so the zipper isn't needed: map over the
root's children, rewriting each into a valid node or dropping it. Reach for
[`greenwood/zipper`][gz] or `cst.zipper_where` only when Error nodes are nested
deeper.

```gleam
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import greenwood.{type Element, type Node, NodeElement, Token, TokenElement}
import molt/value

pub fn yaml_to_toml(source: String) -> Result(String, Nil) {
  let assert Ok(doc) = molt.parse(source)

  let tree = cst.from_document(doc)
  let repaired =
    greenwood.Node(..tree, children: list.filter_map(tree.children, repair))

  let fixed = cst.to_document(repaired)

  case molt.document_errors(fixed) {
    [] -> Ok(molt.to_string(fixed))
    _ -> Error(Nil)
  }
}

// Convert one root child: `Ok(element)` keeps it (possibly rewritten), `Error`
// drops it.
fn repair(el: Element(types.TomlKind)) -> Result(Element(types.TomlKind), Nil) {
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
```

### Interpret each line {#interpret-each-line}

The gotcha: the `molt` parser keeps the colon with the key name, so `host:` is a
single token and the value is also its own token. Drop whitespace and newlines,
then read a trailing colon off the key:

```gleam
fn interpret_tokens(
  children: List(Element(types.TomlKind)),
) -> Option(Node(types.TomlKind)) {
  case meaningful_texts(children) {
    // "---" YAML document separator: drop it.
    ["---", ..] -> None

    // "key:" on its own → a YAML mapping header → a TOML table header.
    [key] -> strip_colon(key) |> option.map(fn(name) { cst.build_table([name]) })

    // "key: value" → a TOML key/value pair.
    [key, value, ..] ->
      strip_colon(key) |> option.map(fn(name) { make_kv_node(name, value) })

    _ -> None
  }
}

fn meaningful_texts(children: List(Element(types.TomlKind))) -> List(String) {
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

fn make_kv_node(key: String, val: String) -> Node(types.TomlKind) {
  cst.build_kv(key:, value: value.to_cst(value.string(val)))
}
```

On the sample that yields:

```toml
[database]
host = "localhost"
port = "5432"
```

The `---` separator is dropped, `database:` becomes a `[database]` header, and
the indented entries become its keys. Values arrive as strings (the parser saw
bare words); a richer converter could feed them through `value.parse_value` to
recover numbers, and track indentation for deeper nesting.

This sort of recovery inherently requires deep heuristics. It assumes you know
the intent behind each line, and real YAML (anchors, nested sequences,
multi-document streams) needs far more logic. Treat it as a starting skeleton,
not a general converter.

Or don't. If you read a `.toml` file that is actually YAML, it's certainly
legitimate to fail entirely.

> This example is verified in [`test/molt/yaml_coercion_test.gleam`][coerce].

## CST Repair Limitations {#cst-repair-limitations}

- CST edits guarantee only _local_ consistency. They can still leave the
  document semantically invalid (a duplicate header, a key/table conflict), so
  always check `molt.has_errors` after `cst.to_document`.
- Replacing an array or inline-table value round-trips it through `Value`, which
  drops interior comments and multiline formatting. Untouched nodes are
  unaffected.
- The `Unterminated*` family and `NoValidTomlStructure` can't be repaired
  programmatically as there are no tokens for the remainder of the document.
  Detect and report them to the user.

[gz]: https://greenwood.hexdocs.pm/greenwood/zipper.html
[coerce]: https://github.com/halostatue/molt/blob/main/test/molt/yaml_coercion_test.gleam
