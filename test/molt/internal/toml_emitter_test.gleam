//// Testing the TOML emitter

import gleam/list
import greenwood.{Node, NodeElement as N, Token, TokenElement as T}
import molt/internal/emitter
import molt/internal/parser
import molt/types

pub fn empty_document_test() {
  assert_round_trip("")
}

pub fn unicode_keys_and_values_test() {
  assert_round_trip(
    "
\"ʎǝʞ\" = \"value\"
\"日本語\" = \"こんにちは\"
emoji = \"🎉🚀\"
\"🎉🚀\" = \"emoji\"
literal_unicode = 'données café'
\"key with spaces\" = true
\"\" = \"blank\"
",
  )
}

pub fn inline_table_tests_test() {
  assert_round_trip(
    "
a = {b = {c = 1}}
points = [{x = 1, y = 2}, {x = 3, y = 4}]
aa = {b = {c = {d = {e = \"deep\"}}}}
tbl = {\n    # name field\n    name = \"test\",\n    count = 1,\n}
",
  )
}

pub fn multiline_basic_string_test() {
  assert_round_trip(
    "
s = \"\"\"
line one
line two\"\"\"

ss = \"\"\"Here are two quotes: \"\". Done.\"\"\"

sss = \"\"\"\\\n    trimmed\"\"\"
",
  )
}

pub fn multiline_literal_string_test() {
  assert_round_trip(
    "
s = '''
no \\escapes
here'''
ss = '''That's a \"quote\"'''
",
  )
}

pub fn basic_string_escapes_test() {
  assert_round_trip(
    "
s = \"\\b\\t\\n\\f\\r\\\"\\\\\"

ss = \"\\u0041\\U00000041\\x41\"

# TOML 1.1: \\e escape
csi = \"\\e[\"
",
  )
}

pub fn empty_table_test() {
  assert_round_trip("[empty]\n")
}

pub fn empty_table_followed_by_another_test() {
  assert_round_trip("[empty]\n[next]\nkey = 1\n")
}

pub fn empty_array_value_test() {
  assert_round_trip("arr = []\n")
}

pub fn empty_inline_table_test() {
  assert_round_trip("obj = {}\n")
}

pub fn table_with_only_comments_test() {
  assert_round_trip("[section]\n# just a comment\n")
}

pub fn array_with_only_whitespace_test() {
  assert_round_trip("arr = [   ]\n")
}

pub fn nested_empty_arrays_test() {
  assert_round_trip("arr = [[], [], []]\n")
}

pub fn simple_dotted_key_test() {
  assert_round_trip("a.b.c = 1\n")
}

pub fn dotted_key_with_spaces_test() {
  assert_round_trip("a . b . c = 1\n")
}

pub fn dotted_key_with_quoted_parts_test() {
  assert_round_trip("site.\"google.com\" = true\n")
}

pub fn multiple_dotted_keys_test() {
  assert_round_trip(
    "fruit.apple.color = \"red\"\nfruit.apple.taste = \"sweet\"\n",
  )
}

pub fn dotted_key_produces_key_node_test() {
  let assert Ok(Node(types.Root, [N(Node(types.KeyValue, kv_children, ..))], ..)) =
    parser.parse("a.b.c = 1\n")

  let assert [N(Node(types.Key, key_children, ..)), ..] = kv_children

  assert key_children
    == [
      T(Token(types.BareKey, "a")),
      T(Token(types.Dot, "")),
      T(Token(types.BareKey, "b")),
      T(Token(types.Dot, "")),
      T(Token(types.BareKey, "c")),
    ]
}

pub fn simple_key_no_key_node_test() {
  let assert Ok(Node(types.Root, [N(Node(types.KeyValue, kv_children, ..))], ..)) =
    parser.parse("name = \"test\"\n")
  let assert [T(Token(types.BareKey, "name")), ..] = kv_children
}

pub fn only_comment_test() {
  assert_round_trip("# just a comment\n")
}

pub fn multiple_comments_test() {
  assert_round_trip("# line 1\n# line 2\n# line 3\n")
}

pub fn only_whitespace_test() {
  assert_round_trip("   \n\n   \n")
}

pub fn comments_and_blank_lines_test() {
  assert_round_trip("# header\n\n# section\n\n")
}

pub fn comment_before_and_after_table_test() {
  assert_round_trip("# before\n[table]\nkey = 1\n# after\n")
}

pub fn array_produces_array_node_test() {
  let assert Ok(doc) = parser.parse("arr = [1, 2, 3]\n")
  let assert [N(kv)] = doc.children
  let has_array =
    list.any(kv.children, fn(el) {
      case el {
        N(n) -> n.kind == types.Array
        _ -> False
      }
    })
  assert has_array
}

pub fn inline_table_produces_node_test() {
  let assert Ok(doc) = parser.parse("obj = {x = 1}\n")
  let assert [N(kv)] = doc.children
  let has_inline =
    list.any(kv.children, fn(el) {
      case el {
        N(n) -> n.kind == types.InlineTable
        _ -> False
      }
    })
  assert has_inline
}

pub fn nested_array_structure_test() {
  let assert Ok(doc) = parser.parse("arr = [[1, 2], [3, 4]]\n")
  let assert [N(kv)] = doc.children
  let has_array =
    list.any(kv.children, fn(el) {
      case el {
        N(n) -> n.kind == types.Array
        _ -> False
      }
    })
  assert has_array
}

pub fn multiline_array_with_comments_test() {
  assert_round_trip("arr = [\n  1,\n  # two\n  2,\n  3,\n]\n")
}

pub fn v1_0_preserves_multiline_array_in_inline_table_test() {
  // A multiline array nested in an inline table is valid TOML 1.0 — newlines
  // between the braces are permitted when they are "valid within a value" — so
  // a 1.0 downgrade must NOT collapse the table onto a single line.
  let source = "a = { b = [\n1, 2, 3\n] }\n"
  let assert Ok(tree) = parser.parse(source)
  assert source == emitter.emit_versioned(node: tree, version: types.v1_0)
}

pub fn v1_0_collapses_multiline_inline_table_test() {
  // A genuine TOML 1.1 multiline inline table (newlines at the table's own
  // structural level) must collapse to a single line for TOML 1.0.
  let assert Ok(tree) = parser.parse("a = { x = 1,\ny = 2 }\n")
  assert "a = { x = 1, y = 2 }\n"
    == emitter.emit_versioned(node: tree, version: types.v1_0)
}

pub fn error_node_for_invalid_line_test() {
  // A line without = should produce an Error node, not KeyValue
  let assert Ok(doc) = parser.parse("not a valid line\n")
  let assert [N(n)] = doc.children
  let assert types.Error = n.kind
}

pub fn complex_roundtrip_test() {
  assert_round_trip(
    "key = \"value\"
a = 1
b = 2
c = 3

[server]
host = \"localhost\"
port = 8080

[a]
x = 1

[b]
y = 2

[[products]]
name = \"Hammer\"
sku = 738594937

[[products]]
name = \"Nail\"

# file header

[server2]
# port config
port = 80

key2 = 42 # the answer

[tools.pontil_build.bundle]
key = \"val\"

point = {x = 1, y = 2}

# TOML 1.1: multiline inline tables
contact = {
    name = \"Tom\",
    email = \"tom@example.com\",
}

ports = [8001, 8001, 8002]

hosts = [
  \"alpha\",
  \"omega\",
]

aa = \"basic\"
bb = 'literal'
cc = \"\"\"
multi
line\"\"\"
dd = '''
raw
'''

s = \"\\t\\n\\\\\\\"\\u0041\\U00000041\\x61\\e\"

n1 = 42
n2 = -17
n3 = 0xDEAD
n4 = 0o755
n5 = 0b1010
n6 = 3.14
n7 = 1e10
n8 = inf
n9 = nan

d1 = 1979-05-27T07:32:00Z
d2 = 1979-05-27T07:32Z
d3 = 1979-05-27T07:32:00
d4 = 1979-05-27T07:32
d5 = 1979-05-27
d6 = 07:32:00
d7 = 14:15

# TOML Example

title = \"TOML Example\"

[owner]
name = \"Tom Preston-Werner\"

[database]
server = \"192.168.1.1\"
ports = [8001, 8001, 8002]
enabled = true

[[products]]
name = \"Hammer\"
sku = 738594937

[[products]]
name = \"Nail\"
sku = 284758393
color = \"gray\"

key  =  \"value\"

[table]\r\nkey = \"val\"\r\n",
  )
}

fn assert_round_trip(source: String) {
  let assert Ok(tokens) = parser.parse(source)
  assert source == emitter.emit(tokens)
}
