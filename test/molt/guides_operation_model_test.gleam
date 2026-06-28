//// Pins the worked example from the usage guide's "Operation Model" section
//// and the recipes at the bottom of the document.
////
//// The same migration is expressed two ways — one atomic `molt.run` batch and
//// a `result.try` chain of high-level functions — and must produce identical,
//// byte-stable output: comments preserved, the inlined/blocked tables placed
//// sensibly. The guide quotes `input` and `expected` verbatim, so this test is
//// what keeps the guide honest.

import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import molt
import molt/error
import molt/ops
import molt/types

const input = "# my_action - example project manifest
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
"

const expected = "# my_action - example project manifest
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
"

fn via_run(source: String) -> Result(String, error.MoltError) {
  use doc <- result.try(molt.parse(source))
  use doc <- result.try(
    molt.run(doc:, ops: [
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
    ]),
  )
  Ok(molt.to_string(doc))
}

fn via_use(source: String) -> Result(String, error.MoltError) {
  use doc <- result.try(molt.parse(source))
  use doc <- result.try(molt.move_keys(
    doc:,
    from: "tools.pontil_build.bundle",
    to: "tools.pontil_build",
    keys: ["esbuild_version", "minify"],
    on_conflict: ops.OnConflictError,
  ))
  use doc <- result.try(molt.move(
    doc:,
    from: "tools.pontil_build.bundle",
    to: "tools.pontil_build.bundle.main",
  ))
  use doc <- result.try(molt.representation(
    doc:,
    path: "repository",
    form: ops.Inline,
  ))
  use doc <- result.try(molt.representation(
    doc:,
    path: "dependencies.squall",
    form: ops.Block,
  ))
  Ok(molt.to_string(doc))
}

pub fn operation_model_run_matches_expected_test() {
  let assert Ok(out) = via_run(input)
  assert out == expected
}

pub fn operation_model_use_matches_run_test() {
  let assert Ok(batch) = via_run(input)
  let assert Ok(chain) = via_use(input)
  assert batch == chain
}

// Recipe: rename a key in every array of tables entry, an optional key when it
// exists, and the array of tables itself.
pub fn bulk_rename_key_across_entries_test() {
  let doc = parse("[[srv]]\naddr = \"a\"\nprt = 22\n\n[[srv]]\naddr = \"b\"\n")

  let assert Ok(indices) =
    molt.length(doc, "srv")
    |> result.map(fn(n) {
      int.range(from: 0, to: n, with: [], run: fn(acc, i) {
        ["srv[" <> int.to_string(i) <> "]", ..acc]
      })
    })

  assert ["srv[1]", "srv[0]"] == indices

  let assert Ok(renamed) =
    list.try_fold(indices, doc, fn(doc, entry) {
      use doc <- result.try(molt.rename(doc, entry <> ".addr", "host"))

      let port = entry <> ".prt"
      use <- bool.guard(!molt.has(doc, port), return: Ok(doc))
      molt.rename(doc, port, "port")
    })
    |> result.try(molt.rename(_, "srv", "server"))

  assert molt.to_string(renamed)
    == "[[server]]\nhost = \"a\"\nport = 22\n\n[[server]]\nhost = \"b\"\n"
}

// Recipe: copy entries
pub fn duplicate_aot_entry_test() {
  let doc = parse("[[item]]\nname = \"x\"\nqty = 1\n")

  let assert Ok(value) = molt.get(doc, "item[0]")

  let assert Ok(duplicated) =
    molt.append(doc, "item", value)
    |> result.try(molt.place(_, "default_item", value))

  assert molt.to_string(duplicated)
    == "[[item]]\nname = \"x\"\nqty = 1\n\n[[item]]\nname = \"x\"\nqty = 1\n\n[default_item]\nname = \"x\"\nqty = 1\n"
}

fn parse(src: String) -> types.Document {
  let assert Ok(doc) = molt.parse(src)
  doc
}
