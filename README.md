# `molt`: TOML Transformed

[![Hex.pm][shield-hex]][hexpm] [![Hex Docs][shield-docs]][docs]
[![Apache 2.0][shield-licence]][licence] ![Erlang Compatible][shield-erl]
![JavaScript Compatible][shield-js]

- code :: <https://github.com/halostatue/molt>
- issues :: <https://github.com/halostatue/molt/issues>

Molt is a TOML transformation library intended to help tool authors make
modifications to configuration TOML files without accidentally affecting any
comments or formatting that preexists. Molt provides complete TOML 1.0 and 1.1
specification compliance. It provides both logical and structural manipulation
API surfaces.

```sh
gleam add molt@1
```

```gleam
import molt
import molt/value

const config = "[server]
host = \"localhost\"
port = 8080

# TLS settings
[server.tls]
enabled = false
"

pub fn main() {
  let assert Ok(doc) = molt.parse(config)

  // Read a value
  let assert Ok(port) = molt.get(doc, "server.port")
  let assert Ok(8080) = value.unwrap_int(port)

  // Edit: change port and enable TLS — comments and formatting preserved
  let assert Ok(doc) = molt.set(doc, "server.port", value.int(443))
  let assert Ok(doc) = molt.set(doc, "server.tls.enabled", value.bool(True))

  molt.to_string(doc)
  // [server]
  // host = "localhost"
  // port = 443
  //
  // # TLS settings
  // [server.tls]
  // enabled = true
}
```

Learn more about how Molt works in the [Usage Guide][usage] and the
[Operations Guide][operations] before reading the rest of the
[documentation][docs].

## Batch Edits

```gleam
import molt
import molt/ops
import molt/value

const input = "[database]
host = \"db.internal\"
port = 5432
pool_size = 10
timeout = 30

[database.replica]
host = \"replica.internal\"
port = 5432
"

pub fn main() {
  let assert Ok(doc) = molt.parse(input)

  // Rename a key, move settings between tables, convert to inline
  let assert Ok(doc) =
    molt.run(doc, [
      ops.Rename(path: "database.host", to: "hostname"),
      ops.MoveKeys(
        from: "database",
        to: "database.replica",
        keys: ["pool_size", "timeout"],
        on_conflict: ops.OnConflictSkip,
      ),
      ops.Representation(path: "database.replica", form: ops.Inline),
    ])

  molt.to_string(doc)
}
```

## Invalid TOML Recovery

When `molt.parse` encounters invalid values, it still returns a usable tree. The
CST layer lets you surgically fix the broken node:

```gleam
import gleam/result
import molt
import molt/cst
import molt/types.{KeySegment}
import molt/value

pub fn main() {
  // pi = 3..14 is not a valid TOML float
  let assert Ok(doc) = molt.parse("pi = 3..14\n")
  assert molt.has_errors(doc)

  // Fix via CST: replace the bad value, keeping the key and formatting
  let assert Ok(tree) =
    cst.from_document(doc)
    |> cst.update(path: [KeySegment("pi")], with: fn(kv) {
      let assert Ok(fixed) =
        cst.set_kv_value(kv:, value: value.to_cst(value.float(3.14)))
      fixed
    })

  let doc = cst.to_document(tree)
  assert !molt.has_errors(doc)
  molt.to_string(doc)
  // -> "pi = 3.14\n"
}
```

This can be explored more completely with the [Repairing Invalid TOML][repair]
guide.

## Semantic Versioning

`molt` follows [Semantic Versioning 2.0][semver].

[docs]: https://molt.hexdocs.pm/
[hexpm]: https://hex.pm/packages/molt
[licence]: https://github.com/halostatue/molt/blob/main/LICENCE.md
[operations]: https://molt.hexdocs.pm/operations.html
[repair]: https://molt.hexdocs.pm/invalid-toml.html
[semver]: https://semver.org/
[shield-docs]: https://img.shields.io/badge/hex-docs-lightgreen.svg?style=for-the-badge "Hex Docs"
[shield-erl]: https://img.shields.io/badge/target-erlang-f3e155?style=for-the-badge "Erlang Compatible"
[shield-hex]: https://img.shields.io/hexpm/v/molt?style=for-the-badge "Hex Version"
[shield-js]: https://img.shields.io/badge/target-javascript-f3e155?style=for-the-badge "JavaScript Compatible"
[shield-licence]: https://img.shields.io/hexpm/l/molt?style=for-the-badge&label=licence "Licence"
[usage]: https://molt.hexdocs.pm/usage.html
