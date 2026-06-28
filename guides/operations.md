# `molt` Operations

Every edit in molt is an `ops.Operation`. The high-level functions on `molt`
(e.g. `molt.set`) are each single-operation sugar over `molt.run`, which applies
a list of `molt/ops` operations to a document.

```gleam
import molt
import molt/ops
import molt/value
```

`molt.run` folds operations over the document, short-circuiting on the first
error: either the document is fully transformed, or you get the `Error` from the
operation that failed and your original `doc` binding is left untouched. It
refuses to run against a document that still has validation errors (see the
[usage guide](usage.md#validation-and-repair)). Every example below shows the
single-operation function form _and_ its `molt.run` batch equivalent; the two
are exactly interchangeable.

Operations are grouped in this document by purpose: writing values, relocating
nodes, array and table editing, representation, and comments.

| Operation                           | Function form         | Summary                                             |
| ----------------------------------- | --------------------- | --------------------------------------------------- |
| [`Append`](#append)                 | `molt.append`         | Append one value to an array / array of tables      |
| [`Concat`](#concat)                 | `molt.concat`         | Append several values at once                       |
| [`EnsureExists`](#ensure-exists)    | `molt.ensure_exists`  | Ensure a table / array of tables exists             |
| [`Insert`](#insert)                 | `molt.insert`         | Insert into an array before an index                |
| [`InsertKey`](#insert-key)          | `molt.insert_key`     | Insert a key/value before an existing key           |
| [`MergeValues`](#merge-values)      | `molt.merge_values`   | Write key/value entries into a table                |
| [`Move`](#move)                     | `molt.move`           | Relocate a key or table                             |
| [`MoveComments`](#move-comments)    | `molt.move_comments`  | Move comments between nodes                         |
| [`MoveKeys`](#move-keys)            | `molt.move_keys`      | Move a subset of keys between tables                |
| [`Place`](#place)                   | `molt.place`          | Unconditionally write any value or structural value |
| [`Remove`](#remove)                 | `molt.remove`         | Delete the node at a path                           |
| [`Rename`](#rename)                 | `molt.rename`         | Rename the last path segment                        |
| [`Representation`](#representation) | `molt.representation` | Convert a table between block and inline form       |
| [`Set`](#set)                       | `molt.set`            | Create or overwrite a scalar/array/inline value     |
| [`SetComments`](#set-comments)      | `molt.set_comments`   | Replace comments on a node                          |
| [`Transfer`](#transfer)             | `molt.transfer`       | Move all keys, then delete the source table         |
| [`Update`](#update)                 | `molt.update`         | Transform a value via a callback                    |

Examples below use small, focused documents so each input and output is exact.
Molt preserves the formatting, comments, and whitespace of every node an
operation does not touch; newly created nodes get uniform formatting.

## `Set` {#set}

```gleam
Set(path: String, value: Value)
molt.set(doc: Document, path: String, value: Value)
```

Creates or overwrites a scalar, array, or inline-table value at `path`. If
`path` does not exist it is created, with implicit ancestors as needed; if it
resolves to an existing value node, the value is replaced in place, preserving
its surrounding formatting and comments.

`Set` deals in value nodes only — on both the `path` and the `value` side — and
returns `TypeMismatch` when either would be structural:

- If `path` resolves to a structural node (a section table, array of tables, or
  implicit table). Use `Place` or `Representation` to overwrite structure.

- If `value` would render a structural node (a section table or array of
  tables): the _intent_ of those `Value` shapes is a header, not a value. To
  write a `[header]` / `[[header]]`, use `Place`; to write the same data inline,
  coerce first with `value.as_inline_table` or `value.as_array`.

_**Input**_

```toml
gleam = 1
```

_**|> Transform**_

```gleam
molt.set(doc, "a.b", value.int(42))
```

```gleam
molt.run(doc, [
  ops.Set(path: "a.b", value: value.int(42)),
])
```

_**⇒ Output**_

```toml
gleam = 1
a.b = 42
```

## `Place` {#place}

```gleam
Place(path: String, value: Value)
molt.place(doc: Document, path: String, value: Value)
```

Writes `value` at `path`, removing whatever is already there first. Unlike
`Set`, `Place` accepts structural values, so it can replace a value with a table
or a table with a value.

_**Input**_

```toml
server = "old"
```

_**|> Transform**_

```gleam
molt.place(
  doc,
  "server",
  value.table([#("host", value.string("localhost"))]),
)
```

```gleam
molt.run(doc, [
  ops.Place(
    path: "server",
    value: value.table([#("host", value.string("localhost"))]),
  ),
])
```

_**⇒ Output**_

```toml
server = { host = "localhost" }
```

## `Remove` {#remove}

```gleam
Remove(path: String)
molt.remove(doc: Document, path: String)
```

Deletes the node at `path`. If the path resolves to an implicit table, the
implicit table and _all_ concrete nodes beneath it are removed.

In the example below `a.b` is an implicit table (implied by `a.b.q` and the
`[a.b.c]` header), so removing it takes `a.b.q` and the whole `[a.b.c]` subtree
with it. To delete a single leaf, target it directly with
`molt.remove(doc, "a.b.q")`.

_**Input**_

```toml
gleam = 1
a.b.q = 42

[a.b.c]
d = 67
```

_**|> Transform**_

```gleam
molt.remove(doc, "a.b")
```

```gleam
molt.run(doc, [ops.Remove(path: "a.b")])
```

_**⇒ Output**_

```toml
gleam = 1
```

## `Move` {#move}

```gleam
Move(from: String, to: String)
molt.move(doc: Document, from: String, to: String)
```

Relocates a node from `from` to `to`. The destination must not already exist and
its last segment must be a key (not an index). Works for keys, tables, and array
of tables. Moving a table rewrites its header: `molt.move(doc, "a.b", "c")`
turns `[a.b]` into `[c]`, carrying its keys and comments along.

_**Input**_

```toml
[a]
x = 10
y = 20

[b]
z = 30
```

_**|> Transform**_

```gleam
molt.move(doc, "a.y", "b.y")
```

```gleam
molt.run(doc, [ops.Move(from: "a.y", to: "b.y")])
```

_**⇒ Output**_

```toml
[a]
x = 10

[b]
z = 30
y = 20
```

## `Rename` {#rename}

```gleam
Rename(path: String, to: String)
molt.rename(doc: Document, path: String, to: String)
```

Renames the last segment of `path` to `to`. The new name must not already exist
as a sibling. Renaming an implicit table updates every concrete descendant that
references it. For a table, `molt.rename(doc, "a.b", "config")` renames the last
segment only: `[a.b]` becomes `[a.config]`.

_**Input**_

```toml
rating = 4.5
```

_**|> Transform**_

```gleam
molt.rename(doc, "rating", "score")
```

```gleam
molt.run(doc, [ops.Rename(path: "rating", to: "score")])
```

_**⇒ Output**_

```toml
score = 4.5
```

## `MoveKeys` {#move-keys}

```gleam
MoveKeys(
  from: String,
  to: String,
  keys: List(String),
  on_conflict: ConflictStrategy
)
molt.move_keys(
  doc: Document,
  from: String,
  to: String,
  keys: List(String),
  on_conflict: ConflictStrategy,
)
```

Moves the named `keys` from the table at `from` into the table at `to`. Keys not
present in `from` are ignored. If `to` does not exist (or is implicit) a
concrete table is created. `on_conflict` follows the
[conflict strategies](#conflict-strategy).

_**Input**_

```toml
[source]
a = 1
b = 2
c = 3

[target]
z = 99
```

_**|> Transform**_

```gleam
molt.move_keys(
  doc,
  from: "source",
  to: "target",
  keys: ["a", "b"],
  on_conflict: ops.OnConflictError,
)
```

```gleam
molt.run(doc, [
  ops.MoveKeys(
    from: "source",
    to: "target",
    keys: ["a", "b"],
    on_conflict: ops.OnConflictError,
  ),
])
```

_**⇒ Output**_

```toml
[source]
c = 3

[target]
z = 99
a = 1
b = 2
```

## `Transfer` {#transfer}

```gleam
Transfer(from: String, to: String, on_conflict: ConflictStrategy)
molt.transfer(
  doc: Document,
  from: String,
  to: String,
  on_conflict: ConflictStrategy,
)
```

Moves _all_ keys from `from` into `to`, then removes the now-empty `from` table.
`to` is created if it does not exist. `on_conflict` follows the
[conflict strategies](#conflict-strategy).

_**Input**_

```toml
[old]
a = 1
b = 2

[new]
z = 9
```

_**|> Transform**_

```gleam
molt.transfer(
  doc,
  from: "old",
  to: "new",
  on_conflict: ops.OnConflictError,
)
```

```gleam
molt.run(doc, [
  ops.Transfer(
    from: "old",
    to: "new",
    on_conflict: ops.OnConflictError
  ),
])
```

_**⇒ Output**_

```toml
[new]
z = 9
a = 1
b = 2
```

## `MergeValues` {#merge-values}

```gleam
MergeValues(
  path: String,
  entries: List(#(String, Value)),
  on_conflict: ConflictStrategy,
)
molt.merge_values(
  doc: Document,
  path: String,
  entries: List(#(String, Value)),
  on_conflict: ConflictStrategy,
)
```

Writes a list of `#(key, value)` entries into the concrete table (or array of
tables entry) at `path`. Each entry key is parsed as a path relative to `path`,
so dotted keys nest. `on_conflict` follows the
[conflict strategies](#conflict-strategy), applied per existing leaf key.

_**Input**_

```toml
[server]
host = "localhost"
```

_**|> Transform**_

```gleam
molt.merge_values(
  doc,
  "server",
  [#("port", value.int(8080)), #("timeout", value.int(30))],
  ops.OnConflictOverwrite,
)
```

```gleam
molt.run(doc, [
  ops.MergeValues(
    path: "server",
    entries: [
      #("port", value.int(8080)),
      #("timeout", value.int(30))
    ],
    on_conflict: ops.OnConflictOverwrite,
  ),
])
```

_**⇒ Output**_

```toml
[server]
host = "localhost"
port = 8080
timeout = 30
```

## `Append` {#append}

```gleam
Append(path: String, value: Value)
molt.append(doc: Document, path: String, value: Value)
```

Appends one `value` to the array (or array of tables) at `path`. For an array of
tables the value must be table-like; appending one adds a new `[[…]]` entry. The
first example below appends to a plain array, the second to an array of tables.

_**Input**_

```toml
tags = ["a", "b"]
```

_**|> Transform**_

```gleam
molt.append(doc, "tags", value.string("c"))
```

```gleam
molt.run(doc, [
  ops.Append(path: "tags", value: value.string("c")),
])
```

_**⇒ Output**_

```toml
tags = ["a", "b", "c"]
```

_**Input**_

```toml
[[plugins]]
name = "formatter"
```

_**|> Transform**_

```gleam
molt.append(
  doc,
  "plugins",
  value.table([#("name", value.string("linter"))]),
)
```

```gleam
molt.run(doc, [
  ops.Append(
    path: "plugins",
    value: value.table([#("name", value.string("linter"))]),
  ),
])
```

_**⇒ Output**_

```toml
[[plugins]]
name = "formatter"

[[plugins]]
name = "linter"
```

## `Concat` {#concat}

```gleam
Concat(path: String, values: List(Value))
molt.concat(doc: Document, path: String, values: List(Value))
```

Like `Append`, but adds several values in one operation.

_**Input**_

```toml
tags = ["a"]
```

_**|> Transform**_

```gleam
molt.concat(doc, "tags", [value.string("b"), value.string("c")])
```

```gleam
molt.run(doc, [
  ops.Concat(
    path: "tags",
    values: [value.string("b"), value.string("c")]
  ),
])
```

_**⇒ Output**_

```toml
tags = ["a", "b", "c"]
```

## `Insert` {#insert}

```gleam
Insert(path: String, before: Int, value: Value)
molt.insert(doc: Document, path: String, before: Int, value: Value)
```

Inserts `value` before index `before` in the array at `path`. Negative indexes
count from the end: `before: -1` inserts before the last element, `before: 0`
inserts at the front.

_**Input**_

```toml
tags = ["a", "c"]
```

_**|> Transform**_

```gleam
molt.insert(doc, "tags", before: 1, value: value.string("b"))
```

```gleam
molt.run(doc, [
  ops.Insert(path: "tags", before: 1, value: value.string("b")),
])
```

_**⇒ Output**_

```toml
tags = ["a", "b", "c"]
```

## `InsertKey` {#insert-key}

```gleam
InsertKey(path: String, before: String, key: String, value: Value)
molt.insert_key(
  doc: Document,
  path: String,
  before: String,
  key: String,
  value: Value,
)
```

Inserts a key/value pair before an existing key in the table at `path`,
preserving order. If `before` is not found, the new entry is appended.

_**Input**_

```toml
[server]
host = "localhost"
port = 8080
```

_**|> Transform**_

```gleam
molt.insert_key(
  doc,
  "server",
  before: "port",
  key: "timeout",
  value: value.int(30),
)
```

```gleam
molt.run(doc, [
  ops.InsertKey(
    path: "server",
    before: "port",
    key: "timeout",
    value: value.int(30),
  ),
])
```

_**⇒ Output**_

```toml
[server]
host = "localhost"
timeout = 30
port = 8080
```

## `EnsureExists` {#ensure-exists}

```gleam
EnsureExists(path: String, kind: TomlKind)
molt.ensure_exists(doc: Document, path: String, kind: TomlKind)
```

Creates a table or array of tables at `path`. If the structure already exists,
nothing changes; if `path` is an implicit table and `kind` is `types.Table`, the
implicit table is promoted into an explicit header. The `kind` parameter must be
`types.Table` or `types.ArrayOfTables`.

_**Input**_

```toml
[a]
x = 1
```

_**|> Transform**_

```gleam
import molt/types

molt.ensure_exists(doc, "b", types.Table)
```

```gleam
molt.run(doc, [
  ops.EnsureExists(path: "b", kind: types.Table),
])
```

_**⇒ Output**_

```toml
[a]
x = 1

[b]
```

## `Representation` {#representation}

```gleam
Representation(path: String, form: Form)
molt.representation(doc: Document, path: String, form: Form)
```

Converts the table or array of tables at `path` between block form (`[table]`
headers) and inline form (`{ … }` / `[{ … }]`). Data is preserved; only the
representation changes. Conversions that would produce invalid TOML (e.g.
inlining a table with sub-table descendants) are rejected. The example below
converts to inline form with [`ops.Inline`](#form), then feeds that result back
through the reverse, `ops.Block`, to recover the block form.

_**Input**_

```toml
[server]
host = "localhost"
port = 8080
```

_**|> Transform**_

```gleam
molt.representation(doc, "server", ops.Inline)
```

```gleam
molt.run(doc, [
  ops.Representation(path: "server", form: ops.Inline),
])
```

_**⇒ Output**_

```toml
server = { host = "localhost", port = 8080 }
```

_**|> Transform**_

```gleam
molt.representation(doc, "server", ops.Block)
```

```gleam
molt.run(doc, [
  ops.Representation(path: "server", form: ops.Block),
])
```

_**⇒ Output**_

```toml
[server]
host = "localhost"
port = 8080
```

## `Update` {#update}

```gleam
Update(path: String, with: fn(Value) -> Result(Value, MoltError))
molt.update(
  doc: Document,
  path: String,
  with: fn(Value) -> Result(Value, MoltError)
)
```

Transforms the value at `path` through a callback returning
`Result(Value, MoltError)`. Only scalar, array, and inline-table values are
permitted; structural types are rejected. Round-tripping an array or inline
table through `Value` drops interior comments and multiline formatting.

To fail the update with a custom message, return
`Error(molt.update_error("reason"))` from the callback. `molt.run` then
short-circuits and returns that `UpdateError`.

_**Input**_

```toml
[server]
port = 8080
```

_**|> Transform**_

```gleam
molt.update(doc, "server.port", fn(v) {
  case value.unwrap_int(v) {
    Ok(n) -> Ok(value.int(n * 2))
    Error(e) -> Error(e)
  }
})
```

```gleam
molt.run(doc, [
  ops.Update(path: "server.port", with: fn(v) {
    value.unwrap_int(v)
    |> result.map(fn(n) { value.int(n * 2 )})
  }),
])
```

_**⇒ Output**_

```toml
[server]
port = 16160
```

## `SetComments` {#set-comments}

```gleam
SetComments(path: String, comments: Comments)
molt.set_comments(doc: Document, path: String, comments: Comments)
```

Replaces the comments on the node at `path` with an [`ops.Comments`](#comments)
value: leading lines above the node, and an optional trailing comment on its
line. The path must resolve to a concrete node (not an implicit table) or the
root of the document (`""`). To read comments back, see `molt.get_comments` in
the [usage guide](usage.md#reading-values).

_**Input**_

```toml
[server]
port = 8080
```

_**|> Transform**_

```gleam
import gleam/option.{Some}

molt.set_comments(
  doc,
  "server.port",
  ops.Comments(
    leading: ["Listen port"],
    trailing: Some("default")
  ),
)
```

```gleam
molt.run(doc, [
  ops.SetComments(
    path: "server.port",
    comments: ops.Comments(
      leading: ["Listen port"],
      trailing: Some("default")
    ),
  ),
])
```

_**⇒ Output**_

```toml
[server]
# Listen port
port = 8080 # default
```

## `MoveComments` {#move-comments}

```gleam
MoveComments(from: String, to: String)
molt.move_comments(doc: Document, from: String, to: String)
```

Moves the comments from the node at `from` to the node at `to`. Both must be
concrete nodes or the root of the document (`""`).

_**Input**_

```toml
# keep me
host = "localhost"
port = 8080
```

_**|> Transform**_

```gleam
molt.move_comments(doc, "host", "port")
```

```gleam
molt.run(doc, [ops.MoveComments(from: "host", to: "port")])
```

_**⇒ Output**_

```toml
host = "localhost"
# keep me
port = 8080
```

## Parameter Types {#parameter-types}

A few operations take a dedicated `molt/ops` type as an argument. They are
collected here and linked from the operations that use them.

### Conflict Strategies {#conflict-strategy}

`MoveKeys`, `Transfer`, and `MergeValues` take an `on_conflict` argument
(`ops.ConflictStrategy`) that decides what happens when a key being written
already exists in the destination:

- `ops.OnConflictError`: abort the whole operation with an error, changing
  nothing.
- `ops.OnConflictOverwrite`: replace the existing destination value with the
  incoming one.
- `ops.OnConflictSkip`: keep the existing destination value and drop the
  incoming one.

### Comments {#comments}

`SetComments` takes an `ops.Comments(leading:, trailing:)`: `leading` is the
list of comment lines above the node, and `trailing` is an optional inline
comment on the node's own line. A leading `#` is added automatically if you omit
it.

### Representation Form {#form}

`Representation` takes a `Form`: `ops.Inline` converts a table to inline form
(`{ … }` / `[{ … }]`), and `ops.Block` converts it back to block form (`[table]`
headers).

## Batch Execution {#batch-execution}

`molt.run` applies a list of operations as one atomic batch: it folds them over
the document in order and short-circuits on the first error. Either every
operation applies and you get the transformed document, or one fails and you get
its `Error`. In the example below, if `rating` does not exist, `molt.run`
returns that operation's `Error`.

```gleam
let assert Ok(doc) =
  molt.run(doc, [
    ops.Set(path: "name", value: value.string("my_action")),
    ops.Rename(path: "rating", to: "score"),
    ops.MoveKeys(
      from: "build.bundle",
      to: "build",
      keys: ["minify"],
      on_conflict: ops.OnConflictError,
    ),
    ops.Representation(path: "repository", form: ops.Inline),
  ])
```

## Recipes {#recipes}

The operations and the high-level functions in molt provide a rich vocabulary
for document migrations, but some complex edits require using these in
interesting ways. This is a collection of useful recipes from these functions
and operations.

### Rename a Key in All Array of Tables Entries

If you need to rename all instances of a key in an array of tables, it's
necessary to loop over each entry to perform the rename. This recipe shows
renaming the `srv` array of tables to `server` and in each entry, the required
key `addr` to `host`, and the optional key `prt` to `port`.

_**Input**_

```toml
[[srv]]
addr = "a"
prt = 22

[[srv]]
addr = "b"
```

_**|> Transform**_

```gleam
import gleam/bool
import gleam/int
import gleam/list

let assert Ok(indices) =
  molt.length(doc, "srv")
  |> result.map(fn(n) {
    int.range(from: 0, to: n, with: [], run: fn(acc, i) {
      ["srv[" <> int.to_string(i) <> "]", ..acc]
    })
  })

let assert Ok(renamed) =
  list.try_fold(indices, doc, fn(doc, entry) {
    use doc <- result.try(molt.rename(doc,entry <> ".addr", "host"))

    let port = entry <> ".prt"

    use <- bool.guard(!molt.has(doc, port), return: Ok(doc))
    molt.rename(doc, port, "port")
  })
  |> result.try(molt.rename("srv", "server"))
```

_**⇒ Output**_

```toml
[[server]]
host = "a"
port = 22

[[server]]
host = "b"
```

### Copy a Table

There is no `Copy` operation, but with `molt.get` and either `molt.place` or
`molt.append` you can copy the contents of tables to new locations.

_**Input**_

```toml
[[item]]
name = "x"
qty = 1
```

_**|> Transform**_

```gleam
import gleam/result

let assert Ok(value) = molt.get(doc, "item[0]")

let assert Ok(duplicated) =
  molt.append(doc, "item", value)
  |> result.try(molt.place(_, "default_item", value))
```

_**⇒ Output**_

```toml
[[item]]
name = "x"
qty = 1

[[item]]
name = "x"
qty = 1

[default_item]
name = "x"
qty = 1
```
