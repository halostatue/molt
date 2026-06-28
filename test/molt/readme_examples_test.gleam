//// Pins the code examples in README.md so they cannot drift from reality.

import molt
import molt/cst
import molt/ops
import molt/types.{KeySegment}
import molt/value

// Example 1: Parse, read, edit, emit

const example1_input = "[server]
host = \"localhost\"
port = 8080

# TLS settings
[server.tls]
enabled = false
"

const example1_expected = "[server]
host = \"localhost\"
port = 443

# TLS settings
[server.tls]
enabled = true
"

pub fn example1_parse_read_edit_emit_test() {
  let assert Ok(doc) = molt.parse(example1_input)

  let assert Ok(port) = molt.get(doc, "server.port")
  let assert Ok(8080) = value.unwrap_int(port)

  let assert Ok(doc) = molt.set(doc, "server.port", value.int(443))
  let assert Ok(doc) = molt.set(doc, "server.tls.enabled", value.bool(True))

  assert molt.to_string(doc) == example1_expected
}

// Example 2: Batch edits

const example2_input = "[database]
host = \"db.internal\"
port = 5432
pool_size = 10
timeout = 30

[database.replica]
host = \"replica.internal\"
port = 5432
"

const example2_expected = "[database]
hostname = \"db.internal\"
port = 5432
replica = { host = \"replica.internal\", port = 5432, pool_size = 10, timeout = 30 }
"

pub fn example2_batch_edits_test() {
  let assert Ok(doc) = molt.parse(example2_input)

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

  assert molt.to_string(doc) == example2_expected
}

// Example 3: CST recovery

pub fn example3_cst_recovery_test() {
  let assert Ok(doc) = molt.parse("pi = 3..14\n")
  assert molt.has_errors(doc)

  let assert Ok(tree) =
    cst.from_document(doc)
    |> cst.update(path: [KeySegment("pi")], with: fn(kv) {
      let assert Ok(fixed) =
        cst.set_kv_value(kv:, value: value.to_cst(value.float(3.14)))
      fixed
    })

  let doc = cst.to_document(tree)
  assert !molt.has_errors(doc)
  assert molt.to_string(doc) == "pi = 3.14\n"
}
