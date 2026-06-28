import argv
import gleam/bit_array
import gleam/bool
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import molt
import molt/error
import molt/types
import simplifile

pub type SuiteError {
  ManifestError(path: String, error: simplifile.FileError)
  FileError(path: String, error: simplifile.FileError)
  MoltError(path: String, error: error.MoltError)
  InvalidUtf8(path: String)
  RoundtripError(path: String)
  NoMoltError(path: String)
  NormalizeValidateError(path: String, errors: List(types.SyntaxError))
}

pub type SuiteType {
  Valid
  Invalid
}

pub fn describe_error(error: SuiteError) -> String {
  case error {
    ManifestError(path:, error:) ->
      "Manifest " <> path <> "error: " <> simplifile.describe_error(error)
    FileError(path:, error:) -> path <> ": " <> simplifile.describe_error(error)
    MoltError(path:, error:) -> path <> ": " <> error.describe_error(error)
    InvalidUtf8(path:) -> path <> ": invalid UTF-8 found"
    RoundtripError(path:) -> path <> ": round-trip mismatch"
    NoMoltError(path:) -> path <> ": parse should have failed"
    NormalizeValidateError(path:, errors:) ->
      path
      <> ": normalize introduced validation errors: "
      <> string.inspect(errors)
  }
}

const fixtures_base = "test/toml-fixtures"

pub fn main() {
  let args = argv.load().arguments
  let #(suite_type, filter) = case args {
    ["valid", ..rest] -> #(Valid, string.join(rest, "/"))
    ["invalid", ..rest] -> #(Invalid, string.join(rest, "/"))
    _ -> {
      io.println("Usage: gleam run -m toml_suite -- <valid|invalid> [category]")
      panic as "invalid arguments"
    }
  }

  let assert Ok(all_files) = case suite_type {
    Valid -> valid_suite()
    Invalid -> invalid_suite()
  }

  let files = case filter {
    "" -> all_files
    _ -> {
      let filter = case string.ends_with(filter, ".toml") {
        True -> string.drop_end(filter, 5)
        False -> filter
      }
      list.filter(all_files, fn(f) {
        string.contains(f, "/" <> filter <> "/")
        || string.ends_with(f, "/" <> filter <> ".toml")
      })
    }
  }

  let results = list.map(files, run_test(_, suite_type))
  let failures = list.filter(results, result.is_error)
  let passed = list.length(results) - list.length(failures)

  list.each(failures, fn(f) {
    let assert Error(error) = f
    io.println("FAIL: " <> describe_error(error))
  })

  io.println(
    "\n"
    <> string.inspect(passed)
    <> "/"
    <> string.inspect(list.length(results))
    <> " passed, "
    <> string.inspect(list.length(failures))
    <> " failures",
  )
}

pub fn run_tests(
  suite_type: SuiteType,
) -> Result(List(Result(String, SuiteError)), SuiteError) {
  use suite <- result.try(case suite_type {
    Valid -> valid_suite()
    Invalid -> invalid_suite()
  })

  Ok(list.map(suite, run_test(_, suite_type)))
}

pub fn run_test(
  path: String,
  suite_type: SuiteType,
) -> Result(String, SuiteError) {
  let path = fixture_path(path)
  case suite_type, read_fixture(path) {
    // Non-UTF-8 fixtures in the invalid suite count as rejected (the file
    // can't even be loaded as a Gleam String). For the valid suite they're
    // a real I/O failure.
    Invalid, Error(_) -> Ok(path)
    Valid, Error(error) -> Error(error)
    _, Ok(content) ->
      case suite_type, parse_fixture(path, content) {
        Valid, Ok(_) -> Ok(path)
        Valid, Error(error) -> Error(error)
        Invalid, Ok(doc) -> {
          use <- bool.guard(molt.has_errors(doc), return: Ok(path))
          Error(NoMoltError(path:))
        }
        Invalid, _error -> Ok(path)
      }
  }
}

pub fn run_round_trip_tests() -> Result(
  List(Result(String, SuiteError)),
  SuiteError,
) {
  use suite <- result.try(valid_suite())

  Ok(list.map(suite, run_roundtrip_test))
}

pub fn run_roundtrip_test(path: String) -> Result(String, SuiteError) {
  let path = fixture_path(path)
  use content <- result.try(read_fixture(path))
  use doc <- result.try(parse_fixture(path, content))

  let output =
    doc
    |> molt.set_version(to: molt.v1_1)
    |> molt.to_string
    |> bit_array.from_string

  use <- bool.guard(output == content, return: Ok(path))

  Error(RoundtripError(path))
}

pub fn run_normalize_validate_tests() -> Result(
  List(Result(String, SuiteError)),
  SuiteError,
) {
  use suite <- result.try(valid_suite())
  Ok(list.map(suite, run_normalize_validate_test))
}

pub fn run_normalize_validate_test(path: String) -> Result(String, SuiteError) {
  let path = fixture_path(path)
  use content <- result.try(read_fixture(path))
  use doc <- result.try(parse_fixture(path, content))

  // Skip files with pre-existing parse errors; we only want to catch errors
  // that normalization itself introduces.
  use <- bool.guard(molt.has_errors(doc), return: Ok(path))

  case doc |> molt.normalize |> molt.document_errors {
    [] -> Ok(path)
    errors -> Error(NormalizeValidateError(path:, errors:))
  }
}

pub fn invalid_suite() -> Result(List(String), SuiteError) {
  use manifest <- result.try(read_manifest_file("1.1.0"))

  Ok(suite_from_manifest(manifest, Invalid))
}

pub fn valid_suite() -> Result(List(String), SuiteError) {
  use v1_0 <- result.try(read_manifest_file("1.0.0"))
  use v1_1 <- result.try(read_manifest_file("1.1.0"))

  Ok(suite_from_manifest(v1_0 <> "\n" <> v1_1, Valid))
}

pub fn read_fixture_directory(
  path: String,
) -> Result(List(#(String, BitArray)), SuiteError) {
  let dir = fixture_path(path)
  use files <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(FileError(path:, error: _)),
  )

  let files =
    files
    |> list.filter(string.ends_with(_, ".toml"))
    |> list.sort(string.compare)

  list.try_fold(files, [], fn(acc, path) {
    use data <- result.try({ dir <> "/" <> path } |> read_fixture)

    Ok([#(path, data), ..acc])
  })
  |> result.map(list.reverse)
}

pub fn fixture_path(file: String) -> String {
  fixtures_base <> "/" <> file
}

pub fn read_fixture(path: String) -> Result(BitArray, SuiteError) {
  simplifile.read_bits(path)
  |> result.map_error(FileError(path:, error: _))
}

fn parse_fixture(
  path: String,
  content: BitArray,
) -> Result(types.Document, SuiteError) {
  molt.parse_bits(content)
  |> result.map_error(fn(error) { MoltError(path:, error:) })
}

fn read_manifest_file(version: String) -> Result(String, SuiteError) {
  let path = fixtures_base <> "/files-toml-" <> version

  simplifile.read(path)
  |> result.map_error(fn(error) { ManifestError(path:, error:) })
}

fn suite_from_manifest(
  manifest: String,
  suite_type: SuiteType,
) -> List(String) {
  let prefix = case suite_type {
    Valid -> "valid/"
    Invalid -> "invalid/"
  }

  string.split(manifest, "\n")
  |> list.filter(fn(line) {
    string.starts_with(line, prefix) && string.ends_with(line, ".toml")
  })
  |> list.unique
}
