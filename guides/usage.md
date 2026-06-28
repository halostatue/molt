# `molt` Usage Guide

## Overview {#overview}

Molt is a TOML manipulation library that preserves formatting, comments, and
whitespace when transforming documents. It parses TOML into a concrete syntax
tree (CST) rather than just extracting values, so your edits don't destroy the
human-authored structure of the file.

Molt is _not_ a general-purpose TOML library, but specifically built for safe
programmatic editing of TOML files. For general TOML reading, prefer [tom][tom].

### Two Levels of Abstraction {#two-abstractions}

Molt offers two main API layers.

- **`molt`** (the high-level API): path-addressed logical operations (`set`,
  `remove`, `move`, …) that keep the document semantically valid and preserve
  representation. Each wraps an `molt/ops` `Operation`, applied through
  `molt.run`; the [Operations Reference][ops] catalogues them all.

- **`molt/cst`**: direct, lossless manipulation of concrete syntax tree nodes.
  This lower level API can produce structurally valid (but semantically invalid)
  TOML. Use it for surgery the high-level API can't express (see the
  [Repairing Invalid TOML][rit] guide).

A companion module, **`molt/value`**, models TOML values for reading and
constructing new values to write. This value type preserves _content_, not
necessarily _representation_ (see [The Value Type](#the-value-type)).

## Parsing and Output {#parsing-and-output}

Molt parses a TOML document into a CST and emits it back to text. Parsing is
always done against the TOML 1.1 syntax, and by default `to_string` reproduces
the input _exactly_: every comment, blank line, and bit of whitespace alignment
is preserved. Molt does not reformat, re-quote, or re-version your document
unless you ask it to.

The one representation molt adjusts on its own is key quoting: a key whose name
isn't a valid bare key (it contains spaces, dots, or other special characters)
is quoted automatically on output, so an edit can never emit invalid TOML.
Setting a key named `my key` writes `"my key" = …`, while `simple-key` stays
bare.

```gleam
import molt

const simple_config = "[server]
hostname = \"localhost\"
port     = 8080
options  = {
  # Whether SSL is enabled
  ssl = {
    enabled = true,
    ciphers = ['TLSv1.2', 'TLSv1.3']
  }
}

[database]
url = \"postgres://\"
"

// A TOML 1.1 document: aligned `=`, a multiline inline table with a comment
let assert Ok(doc) = molt.parse(simple_config)

// Round-trip: output matches input byte-for-byte
assert simple_config == molt.to_string(doc)
```

`molt.parse` always builds a CST. It returns an `Error` result only when the
input cannot be parsed at all. A document that parses but is _semantically_
invalid still returns `Ok(doc)` but carries an error count and the details can
be recovered with `molt.document_errors` (see
[Validation and Repair](#validation-and-repair)).

> TOML documents must be UTF-8, so normal Gleam strings are correct most of the
> time. To fully preserve all bytes in a source stream on JavaScript (UTF-8
> BOMs), `molt.parse_bits` may be called. If the provided `BitArray` isn't
> UTF-8, an `InvalidSourceEncoding` error will be returned.

### Output Version {#output-version}

A document may be configured with a version (the default is TOML 1.1), but the
version only matters on output. To output as TOML 1.0, use `set_version` before
output:

```gleam
// The default version is `molt.v1_1`
molt.set_version(doc, to: molt.v1_0)
|> molt.to_string
```

Emitting the `simple_config` document as TOML 1.0 collapses the multiline inline
table to a single line and removes the inline table comment.

```toml
[server]
hostname = "localhost"
port     = 8080
options  = { ssl = { enabled = true, ciphers = ['TLSv1.2', 'TLSv1.3'] } }

[database]
url = "postgres://"
```

There are other document changes when the document is set as TOML 1.0,
including:

- `\xHH` escapes are rewritten as `\u00HH` and `\e` is rewritten as `\u001B`.
- Times omitting seconds have `:00` added.

### Normalizing ("Formatting") {#normalizing}

Molt can also _normalize_ a document independently of the output version.

```gleam
molt.normalize(doc) // can still edit the document
|> molt.to_string   // or output it

// or
molt.to_normalized_string(doc)
```

Normalization of a document tidies a document's formatting in specific
(non-configurable) ways:

- only Unix newlines are used to end lines
- spacing for key / value pairs is rewritten as `key = value`, reducing the
  spacing to a single space before and after the `=`
- comment-free inline arrays and tables are collapsed to single-line formats
- excess whitespace is removed from table headers
- a single blank line is placed between table headers
- the document ends with a single newline

The normalized `simple_config` document becomes:

```toml
[server]
hostname = "localhost"
port = 8080
options = {
  # Whether SSL is enabled
  ssl = {
    enabled = true,
    ciphers = ['TLSv1.2', 'TLSv1.3']
  }
}

[database]
url = "postgres://"
```

### A Note on Line Breaks {#line-breaks}

TOML supports both Unix (`\n`) and Windows (`\r\n`) newlines to mark separated
lines, and Molt leaves parsed newlines unmodified. But what about newlines
inserted when modifying the document? Molt uses the _first_ line break found in
the parsed document to become the newline style used in the rest of the
document. If the document has been created fresh, only Unix newlines will be
used for these added nodes.

When outputting as a normalized document, only Unix newlines are used.

## Paths {#paths}

Every read and write addresses a logical node (a key, a table, or an array
element) by a **path**: a string that names a route from the document root to
the node. Understanding path syntax is understanding molt's lookup model,
because nothing is addressed any other way.

```gleam
molt.get(doc, "server.port")        // the `port` key inside [server]
molt.has(doc, "servers[0].host")    // `host` in the first [[servers]] entry
```

- **Key Segments** are separated by `.`: `a.b.c` descends three levels.

- **Index Segments** use brackets: `servers[0]` selects the first element of an
  array (or array of tables). Negative indexes are supported to count from the
  end, making `tags[-1]` is the last element.

- **Quoted segments** address keys that aren't valid bare keys (keys with
  spaces, dots, or other special characters). Single quotes are literal (no
  escapes); double quotes allow escapes just like in TOML:

  ```gleam
  molt.get(doc, "owner.'first name'")   // key: first name
  molt.get(doc, "owner.\"a.b\"")        // key: a.b a literal dot, not a step
  ```

Lookups resolve by the _resolved_ key name, so a segment matches a key
regardless of how either is written: `a.'x'`, `a."x"`, and `a.x` all resolve to
the same key `x`.

The empty path `""` addresses the document root so that `molt.get(doc, "")`
returns the root as a table value, and `molt.keys(doc, "")` lists the top-level
keys (those before any `[table]` header).

## Reading Values {#reading-values}

```gleam
import molt/value

// Check existence (table, key, or array element)
molt.has(doc, "server")        // → True
molt.has(doc, "server.port")   // → True

// Get a value at a path; molt.get returns an opaque `value.Value`
let assert Ok(port) = molt.get(doc, "server.port")
let assert Ok(8080) = value.unwrap_int(port)

// List the keys of a table
let assert Ok(keys) = molt.keys(doc, "server")
// keys == ["hostname", "port", "options"]

// Length of an array or array of tables
molt.length(doc, "server.tags")  // → Ok(n) or an error if not an array
```

`molt.get(doc, "")` returns the document root as a table value.
`molt.keys(doc, "")` lists the root-level keys.

### Node Comments {#node-comments}

To read a node's comments, `molt.get_comments` returns an
`ops.Comments(leading:, trailing:)` with the comment text verbatim, including
the leading `#`:

```gleam
import molt/ops

let assert Ok(ops.Comments(leading:, trailing:)) =
  molt.get_comments(doc, "server.port")
```

The provided path must resolve to a concrete node (not an implicit table).

### Document Comments {#document-comments}

Molt supports document comments separately from node comments. `Header` comments
begin at the top of the document and continue until there is a blank line.
`Trailer` comments collect all comments from the last value node to the end of
the document. If no blank line exists, then all of the leading comments belong
to the first value node. If a document is only comments, all of the comments
belong to the `Header`.

```toml
# A header comment starts from the beginning of the file until a blank line
# (`\n\n` or `\r\n\r\n`).

# Node leading comment
node = 1 # Node trailing comment
# Trailer comments are any comments that follow the last node, whether there's
# whitespace following the node or not.
```

The functions to manipulate document comments are `molt.get_document_comments`
and `molt.set_document_comments`. Each takes a comment position marker (`Header`
or `Trailer`).

```gleam
let assert Ok(doc) = molt.parse("# title\n\nx = 1\n# end of file\n")

molt.get_document_comments(doc, molt.Header)   // → ["# title"]
molt.get_document_comments(doc, molt.Trailer)  // → ["# end of file"]

let doc = molt.set_document_comments(doc, molt.Trailer, ["bye"])
molt.to_string(doc) // → "# title\n\nx = 1\n\n# bye\n"
```

Passing `[]` clears the comments in the location. Setting a `Trailer` comment
always inserts a blank line before the comments (parsed comments may not have
this blank line).

## The Operation Model {#the-operation-model}

Every edit in molt is an **operation**. The high-level functions (`set`, `move`,
`rename`, `representation`, and the rest) are each single-operation sugar over
`molt.run`, which applies a list of `molt/ops` operations to a document:

```gleam
molt.set(doc, "server.port", value.int(443))
// is exactly
molt.run(doc, [ops.Set(path: "server.port", value: value.int(443))])
```

`molt.run` folds operations over the document, short-circuiting on the first
error. Either the document is fully transformed or the `Error` from the
operation that failed. This makes two natural ways to express a sequence of
edits, and they produce identical results:

- **`molt.run` with a list of operations**: one atomic batch. Best for a
  mechanical recipe that should either all apply or not at all.

- **A chain of the high-level functions, threaded through `result.try`**: a
  step-by-step sequence where each `Result` is in hand, so you can branch,
  inspect, or handle failures between steps.

The full catalogue of operations is the [Operations Reference][ops].

### Migrating a Project Manifest {#migrating-a-project-manifest}

Let's update this project manifest.

```toml
# my_action - example project manifest
name = 'my_action'

# A block table the migration flips to an inline table.
[repository]
type = 'github'
user = 'example-org'
repo = 'my_action'

[dependencies]
gleam_stdlib = '>= 0.44.0 and < 2.0.0'
# Pinned to a git ref until the upstream fix ships.
squall = { git = 'https://github.com/example-org/squall.git', ref = 'fix-dup' }
tom = '>= 2.0.0 and < 3.0.0'

[tools.pontil_build.bundle]
entry = 'my_action.gleam'
esbuild_version = '0.28.0'
minify = true
```

We're going to write two versions of the migration where we:

- promote certain global build settings from `[tools.pontil_build.bundle]` to
  `[tools.pontil_build]`;
- move what remains of `[tools.pontil_build.bundle]` to
  `[tools.pontil_build.bundle.main]`;
- convert `[repository]` to an inline table; and
- convert the inline table `squall` dependency to its own block table.

The migrations can be applied in a single `run`:

```gleam
import molt
import molt/ops

let assert Ok(doc) = molt.parse(source)
let assert Ok(doc) =
  molt.run(doc, [
    ops.MoveKeys(
      from: "tools.pontil_build.bundle",
      to: "tools.pontil_build",
      keys: ["esbuild_version", "minify"],
      on_conflict: ops.OnConflictError,
    ),
    ops.Move(
      from: "tools.pontil_build.bundle",
      to: "tools.pontil_build.bundle.main",
    ),
    ops.Representation(path: "repository", form: ops.Inline),
    ops.Representation(path: "dependencies.squall", form: ops.Block),
  ])

let migrated = molt.to_string(doc)
```

Or they can be applied with `result.try` over `molt` operation functions:

```gleam
import gleam/result
import molt
import molt/ops

let assert Ok(migrated) = {
  use doc <- result.try(molt.parse(source))

  use doc <- result.try(molt.move_keys(
    doc,
    from: "tools.pontil_build.bundle",
    to: "tools.pontil_build",
    keys: ["esbuild_version", "minify"],
    on_conflict: ops.OnConflictError,
  ))

  use doc <- result.try(molt.move(
    doc,
    from: "tools.pontil_build.bundle",
    to: "tools.pontil_build.bundle.main",
  ))

  use doc <- result.try(molt.representation(doc, "repository", ops.Inline))

  use doc <- result.try(
    molt.representation(doc, "dependencies.squall", ops.Block),
  )

  Ok(molt.to_string(doc))
}
```

Either way, the result is the same. Comments ride along with the nodes they
annotate, untouched keys keep their exact formatting, and the new
`[dependencies.squall]` block lands next to its parent:

```toml
# my_action - example project manifest
name = 'my_action'

# A block table the migration flips to an inline table.
repository = { type = 'github', user = 'example-org', repo = 'my_action' }

[dependencies]
gleam_stdlib = '>= 0.44.0 and < 2.0.0'
tom = '>= 2.0.0 and < 3.0.0'

# Pinned to a git ref until the upstream fix ships.
[dependencies.squall]
git = 'https://github.com/example-org/squall.git'
ref = 'fix-dup'

[tools.pontil_build]
esbuild_version = '0.28.0'
minify = true

[tools.pontil_build.bundle.main]
entry = 'my_action.gleam'
```

### Operations at a glance {#operations-at-a-glance}

Each operation has a high-level function (shown) and a matching `ops.Operation`
constructor that `molt.run` takes. Follow a link for the full signature,
behaviour, and examples in the [Operations Reference][ops].

| Function                                                                        | What it does                                                                            |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| [`molt.set`](https://molt.hexdocs.pm/operations.html#set)                       | Upsert a scalar, array, or inline-table value (creating implicit ancestors).            |
| [`molt.update`](https://molt.hexdocs.pm/operations.html#update)                 | Transform an existing value in place via a callback.                                    |
| [`molt.place`](https://molt.hexdocs.pm/operations.html#place)                   | Write a value unconditionally, replacing whatever is there (structural values allowed). |
| [`molt.ensure_exists`](https://molt.hexdocs.pm/operations.html#ensure-exists)   | Ensures a table or array of tables exists.                                              |
| [`molt.remove`](https://molt.hexdocs.pm/operations.html#remove)                 | Delete a node; for an implicit table, everything beneath it.                            |
| [`molt.rename`](https://molt.hexdocs.pm/operations.html#rename)                 | Rename the last segment of a path.                                                      |
| [`molt.move`](https://molt.hexdocs.pm/operations.html#move)                     | Relocate a key, table, or array of tables to a new path.                                |
| [`molt.move_keys`](https://molt.hexdocs.pm/operations.html#move-keys)           | Move named keys between tables, with a conflict strategy.                               |
| [`molt.transfer`](https://molt.hexdocs.pm/operations.html#transfer)             | Move all keys out of a table, then remove the empty source.                             |
| [`molt.merge_values`](https://molt.hexdocs.pm/operations.html#merge-values)     | Write `#(key, value)` entries into a table (keys nest as paths).                        |
| [`molt.append`](https://molt.hexdocs.pm/operations.html#append)                 | Append one value to an array or array of tables.                                        |
| [`molt.concat`](https://molt.hexdocs.pm/operations.html#concat)                 | Append several values to an array.                                                      |
| [`molt.insert`](https://molt.hexdocs.pm/operations.html#insert)                 | Insert into an array before an index (negative counts from the end).                    |
| [`molt.insert_key`](https://molt.hexdocs.pm/operations.html#insert-key)         | Insert a key/value before an existing key, preserving order.                            |
| [`molt.representation`](https://molt.hexdocs.pm/operations.html#representation) | Convert a table or array of tables between inline and block form.                       |
| [`molt.set_comments`](https://molt.hexdocs.pm/operations.html#set-comments)     | Replace a node's leading and trailing comments.                                         |
| [`molt.move_comments`](https://molt.hexdocs.pm/operations.html#move-comments)   | Move comments from one node to another.                                                 |

A few operations take extra `molt/ops` types. `move_keys`, `transfer`, and
`merge_values` take an `ops.ConflictStrategy`, deciding what happens when a
destination key already exists. The comment operations take
`ops.Comments(leading:, trailing:)`, where `leading` is the lines above a node
and `trailing` is the inline comment on its line (the leading `#` is optional;
molt adds it).

## The Value Type {#the-value-type}

`molt/value` represents every TOML value type. `Value` is an **opaque** type
where you build values with the constructor functions below.

```gleam
import molt/value

// Scalars
value.string("hello")        // "hello" (style auto-chosen, see below)
value.int(42)                // 42
value.hex_int(255)           // 0xff
value.octal_int(8)           // 0o10
value.binary_int(5)          // 0b101
value.float(3.14)            // 3.14
value.bool(True)             // true

// Special floats
value.infinity()             // inf
value.signed_infinity(value.Negative)  // -inf
value.nan()                  // nan
value.signed_nan(value.Positive)       // +nan

// Containers
value.array([value.string("THX"), value.int(1187)])
value.table([#("x", value.int(1))])    // an inline table value: { x = 1 }
```

Some constructors validate their input and return `Result(Value, MoltError)`:

```gleam
import molt/value

let assert Ok(t) = value.offset_datetime("2024-01-15T10:30:00Z")
let assert Ok(d) = value.local_date("2024-01-15")
let assert Ok(s) = value.literal_string("C:\\path") // rejects ' and control chars
let assert Ok(m) = value.multiline_literal_string("a\nb")
```

The date/time constructors are `offset_datetime`, `local_datetime`,
`local_date`, `local_time` (and `datetime`, which classifies any of them). Molt
does not model the calendar. A date/time value is treated as validated source
text, so `unwrap_datetime` returns that unmodified.

### Unwrapping Values {#unwrapping-values}

Use the `unwrap_*` accessors (or their `_or` defaulting variants) and the
table/array helpers to obtain Gleam values for the TOML values:

```gleam
value.unwrap_int(v)       // Result(Int, _)
value.unwrap_string(v)    // Result(String, _)
value.unwrap_bool(v)      // Result(Bool, _)
value.unwrap_float(v)     // Result(Float, _)
value.unwrap_datetime(v)  // Result(String, _)

value.unwrap_int_or(v, 0)

value.table_get_key(v, "host")   // Result(Value, _)
value.table_keys(v)              // Result(List(String), _)
value.array_to_list(v)           // Result(List(Value), _)
value.array_get_at(v, -1)        // Result(Value, _)
```

`value.type_of(v)` returns the TOML type name; `value.string_style` and
`value.int_style` report the specific representation.

### Content vs Representation {#content-vs-representation}

`Value`s preserve the _content_ of a value, but not necessarily its
representation. A value read out of a document and written back unchanged
round-trips its original text. When you build a value with a constructor, the
serialization is canonical: `value.hex_int(255)` emits `0xff`, dropping any
original casing or underscores; strings lose multiline/escape styling;
structural values lose comments and formatting.

To create a new value that preserves a _specific_ textual representation, parse
it from text with `value.parse_value`, which retains the source spelling:

```gleam
let assert Ok(v) = value.parse_value("1_000")     // serializes as 1_000
let assert Ok(v) = value.parse_value("0xFF00FF")  // serializes as 0xFF00FF
```

In most cases value-level manipulation is unnecessary: the `molt/ops` operations
driven through `molt.run` (and the high-level functions) preserve the document's
representation for everything they don't touch.

### Comment Loss When Replacing a Container with a Value {#value-comment-loss}

Replacing an array or inline table value (through `molt.update`, `molt.set`, or
other operations that use `Value`) drops the comments _inside_ it.

```toml
arr = [
  1,
  # about two
  2,
  3,
]
```

Given the TOML above, replacing `arr` wholesale loses the `# about two` comment.
This applies equally to arrays and inline tables (including TOML 1.1 multiline
inline tables with interleaved comments).

Targeting a single member instead is an in-place swap that leaves its siblings
and their comments untouched: `molt.set(doc, "arr[0]", value.int(9))` rewrites
just the first element, and the `# about two` comment on the second survives. So
edit the member you mean to change rather than rebuilding the whole container.

Operations that move the container without writing a `Value` over it are
lossless: `molt.move` and `molt.rename` relocate the existing CST nodes, so a
container's interior comments ride along untouched.

### String Quoting Heuristic {#string-quoting-heuristic}

When you build a string with `value.string`, molt selects the style from the
content. It defaults to a basic string and reaches for a literal string only
when that spares escaping, and only when a literal can actually represent the
value.

- **Does it contain a newline (`\n`)?** If so the result is a multiline string
  (`"""…"""` / `'''…'''`); otherwise a single-line string (`"…"` / `'…'`).

- **Would a basic string have to escape anything?** Basic strings escape `"` and
  `\`. If the value contains neither, molt uses the basic form — the
  conventional default. If it contains either, molt prefers the literal form,
  which escapes nothing.

A literal is chosen only when it is _feasible_. A literal string cannot contain
its own delimiter (`'`, or `'''` for a multiline literal) or a control character
other than tab (multiline literals also allow newline and carriage return). When
a literal can't represent the value — it holds a `'`, or a control character
such as ESC or backspace that only an escape can encode — molt falls back to the
basic form and escapes as needed.

| Content                              | Style                                                  |
| ------------------------------------ | ------------------------------------------------------ |
| no `"` or `\`                        | `"basic"` (`"""multiline basic"""` with a newline)     |
| `"` or `\`, literal feasible         | `'literal'` (`'''multiline literal'''` with a newline) |
| `"` or `\`, but literal not feasible | falls back to `"basic"` / `"""multiline basic"""`      |

For explicit control, use `value.basic_string`, `value.multiline_basic_string`,
`value.literal_string`, or `value.multiline_literal_string`, or coerce an
existing string with `value.as_basic_string` and friends.

## Error Handling {#error-handling}

All fallible operations return `Result(_, MoltError)`. The error type and its
human-readable formatter live in `molt/error`:

```gleam
import molt/error
import gleam/io

case molt.set(doc, "server.port", value.int(1)) {
  Ok(doc) -> doc
  Error(err) -> {
    io.println(error.describe_error(err))
    doc
  }
}
```

Common `MoltError` variants (see `molt/error` for the full list):

- `ParseError(message:, offset:)` — the source could not be tokenized.
- `InvalidPath(message:)` — the path string is malformed.
- `NotFound(path:, at:)` — nothing at `path`; `at` shows how far resolution got.
- `AlreadyExists(path:, current:)` — something already exists where a new node
  was required (e.g. a move/rename collision).
- `TypeMismatch(path:, expected:, got:)` — the node at `path` is the wrong
  shape.
- `IndexOutOfRange(path:, index:, length:)` — array index out of bounds.
- `InvalidDocument` — the operation was attempted on a document with unresolved
  validation errors.
- `UpdateError(message:)` — returned by your own `update` callback via
  `molt.update_error`.

> Note: duplicate-key and conflicting-table problems are _validation_ errors,
> not `MoltError`s. They surface via `molt.document_errors` as `SyntaxError`
> values after parsing.

## Validation and Repair {#validation-and-repair}

Molt separates two failure modes:

1. **Unparsable** — `molt.parse` returns `Error(_)`. There is no usable tree.
2. **Parsable but invalid** — `molt.parse` returns `Ok(doc)` with a non-zero
   `molt.error_count(doc)`. The document has a CST but no index, so anything
   that consults the index (both reads and writes alike) returns
   `Error(InvalidDocument)`. This makes it impossible to read or edit
   semantically broken data by accident.

To load a broken document, fix it, and re-check it, repair through the CST
layer, where `cst.to_document` revalidates the tree.

```gleam
import molt
import molt/cst

let assert Ok(doc) = molt.parse(source) // Ok even though doc.error_count > 0
// ... repair via molt/cst edits on cst.from_document(doc) ...
let doc = cst.to_document(repaired_doc) // recomputes doc.error_count
```

If `molt.has_errors(doc)` returns true, you can see the error count with
`molt.error_count(doc)` or the error details with `molt.document_errors(doc)`.
See the [Repairing Invalid TOML][rit] guide for the full workflow.

[tom]: https://tom.hexdocs.pm/
[rit]: https://molt.hexdocs.pm/invalid-toml.html
[ops]: https://molt.hexdocs.pm/operations.html
