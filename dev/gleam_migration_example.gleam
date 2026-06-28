//// gleam.toml Migration Example
////
//// Run with: gleam run -m gleam_migration_example
////
//// Operates on a nominal `sneetches.gleam.toml`, demonstrating that targeted
//// structural edits preserve every comment and bit of formatting they don't
//// touch. Two equivalent implementations are provided:
////
//// - `migrate_run`: one atomic `molt.run` batch of operations.
//// - `migrate_use`: the same operations as a chain of single high-level
////   functions threaded through `result.try`.

import gleam/io
import gleam/list
import gleam/result
import gleam/string
import molt
import molt/error
import molt/ops

/// Keys promoted to [tools.pontil_build] (global config).
const global_keys = [
  "esbuild_version", "autoinstall", "outdir", "minify", "analyze",
  "legal_comments",
]

pub fn main() {
  io.println("=== INPUT ===")
  io.println(input)

  let assert Ok(result) = migrate_run(input)
  let assert Ok(result_use) = migrate_use(input)
  check("run and use styles produce identical output", result == result_use)

  io.println("=== OUTPUT ===")
  io.println(result)

  io.println("=== VERIFICATION ===")
  verify(result)
}

/// All edits as a single atomic batch. `run` applies the operations in order
/// to an immutable document and either returns the fully-edited document or
/// fails without mutating anything — the shape for mechanical recipes that
/// should not partially apply.
pub fn migrate_run(source: String) -> Result(String, error.MoltError) {
  use doc <- result.try(molt.parse(source))

  let bundle = "tools.pontil_build.bundle"
  let build = "tools.pontil_build"
  let main = "tools.pontil_build.bundle.main"

  use doc <- result.try(
    molt.run(doc:, ops: [
      ops.MoveKeys(
        from: bundle,
        to: build,
        keys: global_keys,
        on_conflict: ops.OnConflictError,
      ),
      ops.Move(from: bundle, to: main),
      ops.Representation(path: "repository", form: ops.Inline),
      ops.Representation(path: "dependencies.squall", form: ops.Block),
    ]),
  )

  Ok(molt.to_string(doc))
}

/// The same migration as `migrate_run`, expressed as a chain of single
/// high-level operations rather than one batch. Each `molt.*` function is
/// `run` sugar for a single op; `result.try` short-circuits on the first
/// error, so the chain reads as a sequence of fallible steps.
pub fn migrate_use(source: String) -> Result(String, error.MoltError) {
  use doc <- result.try(molt.parse(source))

  let bundle = "tools.pontil_build.bundle"
  let build = "tools.pontil_build"
  let main = "tools.pontil_build.bundle.main"

  use doc <- result.try(molt.move_keys(
    doc:,
    from: bundle,
    to: build,
    keys: global_keys,
    on_conflict: ops.OnConflictError,
  ))
  use doc <- result.try(molt.move(doc:, from: bundle, to: main))
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

fn verify(result: String) {
  // --- pontil_build migration (MoveKeys + Move) ---
  check(
    "globals promoted to [tools.pontil_build]",
    has_exact_header(result, "[tools.pontil_build]"),
  )
  check(
    "bundle moved to [tools.pontil_build.bundle.main]",
    has_exact_header(result, "[tools.pontil_build.bundle.main]"),
  )
  check(
    "no bare [tools.pontil_build.bundle]",
    !has_exact_header(result, "[tools.pontil_build.bundle]"),
  )
  check(
    "global: esbuild_version",
    string.contains(result, "esbuild_version = \"0.28.0\""),
  )
  check(
    "bundle: entry kept",
    string.contains(result, "entry = \"sneetches_action.gleam\""),
  )
  check(
    "bundle: raw kept",
    string.contains(result, "raw = ['--drop:debugger']"),
  )

  // --- representation changes ---
  check("repository -> inline table", string.contains(result, "repository = {"))
  check(
    "no [repository] block header",
    !has_exact_header(result, "[repository]"),
  )
  check(
    "squall -> block table",
    has_exact_header(result, "[dependencies.squall]"),
  )
  check("no inline squall value", !string.contains(result, "squall = {"))

  // --- preservation of untouched structure ---
  check(
    "preserved: file header comment",
    string.contains(result, "# sneetches - example project manifest"),
  )
  check(
    "preserved: glinter stats comment",
    string.contains(result, "# emit linter stats"),
  )
  check(
    "preserved: quoted-key ignore array",
    string.contains(result, "'src/sneetches/internal/github/*.gleam' = ["),
  )
  check(
    "preserved: dependency tom",
    string.contains(result, "tom = '>= 2.0.0 and < 3.0.0'"),
  )

  // --- output is still valid TOML ---
  check("output re-parses with no errors", case molt.parse(result) {
    Ok(doc) -> !molt.has_errors(doc)
    Error(_) -> False
  })
}

fn check(label: String, condition: Bool) {
  case condition {
    True -> io.println("  ✓ " <> label)
    False -> io.println("  ✗ FAIL: " <> label)
  }
}

fn has_exact_header(text: String, header: String) -> Bool {
  text
  |> string.split("\n")
  |> list.any(fn(line) { string.trim(line) == header })
}

const input = "
# sneetches - example project manifest used by the molt usage guide.
# Comments, inline tables, and untouched formatting survive every operation
# that doesn't address their node.

name = \"sneetches\"
version = \"3.0.1\"
target = 'javascript'

description = \"Generate a list from user starred GitHub repositories\"
licences = ['Apache-2.0']

# A block table — the guide flips this to an inline table.
[repository]
type = 'github'
user = 'example-org'
repo = 'sneetches'

[dependencies]
argv = '>= 1.0.2 and < 2.0.0'
capuchin_crypt = '>= 1.0.0 and < 2.0.0'
clip = '>= 1.2.0 and < 2.0.0'
envoy = '>= 1.1.0 and < 2.0.0'
filepath = '>= 1.0.0 and < 2.0.0'
gleam_fetch = '>= 1.3.0 and < 2.0.0'
gleam_http = '>= 4.3.0 and < 5.0.0'
gleam_javascript = '>= 1.0.0 and < 2.0.0'
gleam_json = '>= 3.0.0 and < 4.0.0'
gleam_stdlib = '>= 0.44.0 and < 2.0.0'
glemplate = '>= 8.0.0 and < 9.0.0'
houdini = '>= 1.2.1 and < 2.0.0'
oaspec = '>= 0.17.0 and < 1.0.0'
oaspec_fetch = '>= 0.1.0 and < 1.0.0'
pontil = '>= 2.0.0 and < 3.0.0'
pontil_context = '>= 1.0.0 and < 2.0.0'
pontil_core = '>= 2.0.0 and < 3.0.0'
pontil_summary = '>= 1.1.0 and < 2.0.0'
shellout = '>= 1.8.0 and < 2.0.0'
simplifile = '>= 2.4.0 and < 3.0.0'
# Pinned to a git ref until the fix ships — an inline table the guide expands
# into a block table.
squall = { git = 'https://github.com/example-org/squall.git', ref = 'fix-duplicate-generation' }
tom = '>= 2.0.0 and < 3.0.0'

[dev_dependencies]
cog = '>= 2.0.3 and < 3.0.0'
gleamy_bench = '>= 0.6.0 and < 1.0.0'
gleeunit = '>= 1.0.0 and < 2.0.0'
glinter = '>= 2.16.0 and < 3.0.0'
pontil_build = '>= 1.0.0 and < 2.0.0'
qcheck = '>= 1.0.0 and < 2.0.0'
take = '>= 1.0.0 and < 2.0.0'

[tools.glinter]
stats = true # emit linter stats

[tools.glinter.rules]
unused_exports = 'off'
ffi_usage = 'error'
function_complexity = 'warning'
module_complexity = 'warning'

[tools.glinter.ignore]
'src/sneetches/internal/github/*.gleam' = [
  'thrown_away_error',
  'function_complexity',
  'missing_labels',
]

# Build config — the guide promotes the global settings up to
# [tools.pontil_build] and moves the bundle to [tools.pontil_build.bundle.main].
[tools.pontil_build.bundle]
entry = \"sneetches_action.gleam\"
outdir = 'dist'
outfile = 'sneetches.cjs'
autoinstall = true
esbuild_version = \"0.28.0\"
minify = true
analyze = 'verbose'
legal_comments = 'external'
raw = ['--drop:debugger']
"
