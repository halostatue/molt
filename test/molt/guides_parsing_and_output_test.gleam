//// Pins the three "Parsing and Output" lenses from the usage guide against
//// `test_documents.simple_config`, a TOML 1.1 document (aligned `=`, a
//// multiline inline table carrying an interior comment):
////
//// - default emit (1.1) round-trips the source byte-for-byte;
//// - the 1.0 downgrade collapses the multiline inline table to one line and
////   drops the interior comment (it cannot survive on a single line), while
////   keeping the `=` alignment;
//// - normalize keeps the multiline table and its comment (only comment-free
////   inline tables collapse) but rewrites the `=` alignment to a single space.
////
//// Each lens touches a different axis, so the guide's three output blocks are
//// pinned here.

import molt
import test_documents as docs

pub fn simple_config_round_trip_test() {
  let assert Ok(doc) = molt.parse(docs.simple_config)
  assert molt.to_string(doc) == docs.simple_config
}

pub fn config_round_trip_test() {
  let assert Ok(doc) = molt.parse(docs.config)
  assert molt.to_string(doc) == docs.config
}

pub fn simple_config_downgrade_1_0_test() {
  let assert Ok(doc) = molt.parse(docs.simple_config)
  let doc = molt.set_version(doc, to: molt.v1_0)
  let expected =
    "[server]
hostname = \"localhost\"
port     = 8080
options  = { ssl = { enabled = true, ciphers = ['TLSv1.2', 'TLSv1.3'] } }

[database]
url = \"postgres://\"
"
  assert molt.to_string(doc) == expected
}

pub fn simple_config_normalize_test() {
  let assert Ok(doc) = molt.parse(docs.simple_config)
  let expected =
    "[server]
hostname = \"localhost\"
port = 8080
options = {
  # Whether SSL is enabled
  ssl = {
    enabled = true,
    ciphers = ['TLSv1.2', 'TLSv1.3']
  }
}

[database]
url = \"postgres://\"
"
  assert molt.to_normalized_string(doc) == expected
}
