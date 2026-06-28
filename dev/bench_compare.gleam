//// Comparative benchmark: molt tokenize+parse vs tom.parse
//// Run with: gleam run -m bench_compare

import gleam/int
import gleam/io
import gleam/string
import gleamy/bench
import molt/internal/parser
import tom

pub fn main() {
  let small_doc = generate_doc(10)
  // let medium_doc = generate_doc(100)
  // let large_doc = generate_doc(250)

  io.println(
    "Small doc: " <> int.to_string(string.length(small_doc)) <> " chars",
  )
  // io.println(
  //   "Medium doc: " <> int.to_string(string.length(medium_doc)) <> " chars",
  // )
  // io.println(
  //   "Large doc: " <> int.to_string(string.length(large_doc)) <> " chars",
  // )
  io.println("")

  bench.run(
    [
      bench.Input("small (10 tables)", small_doc),
      // bench.Input("medium (100 tables)", medium_doc),
    // bench.Input("large (250 tables)", large_doc),
    ],
    [
      bench.Function(
        "tom.parse x 5",
        bench.repeat(5, fn(doc) {
          let assert Ok(_) = tom.parse(doc)
          Nil
        }),
      ),
      bench.Function(
        "molt ball only x 5",
        bench.repeat(5, fn(doc) {
          let _ = parser.parse(doc)
          Nil
        }),
      ),
    ],
    [bench.Duration(2000), bench.Warmup(500)],
  )
  |> bench.table([bench.IPS, bench.Min, bench.Mean, bench.P(99)])
  |> io.println
}

fn generate_doc(num_tables: Int) -> String {
  do_generate(num_tables, 1, "")
}

fn do_generate(remaining: Int, i: Int, acc: String) -> String {
  case remaining {
    0 -> acc
    _ -> {
      let is = int.to_string(i)
      let section =
        "# Configuration for module "
        <> is
        <> "\n"
        <> "[table_"
        <> is
        <> "]\n"
        <> "name = \"value_"
        <> is
        <> "\"\n"
        <> "count = "
        <> int.to_string(i * 100)
        <> "\n"
        <> "ratio = "
        <> int.to_string(i)
        <> ".5\n"
        <> "enabled = true\n"
        <> "tags = [\"tag_a\", \"tag_b\", \"tag_c\"]\n"
        <> "path = 'C:\\Users\\test\\file_"
        <> is
        <> "'\n"
        <> "created = 2024-01-"
        <> pad2(i % 28 + 1)
        <> "T10:30:00Z\n"
        <> "\n"
      do_generate(remaining - 1, i + 1, acc <> section)
    }
  }
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}
