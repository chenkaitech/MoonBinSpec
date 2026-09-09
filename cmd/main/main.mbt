///|
fn print_usage() -> Unit {
  println("moonbinspec <command> [options]")
  println("")
  println("Commands:")
  println("  check <schema.mbs>                    Parse and validate a schema")
  println(
    "  inspect <file> -s <schema.mbs>         Print the decoded field tree",
  )
  println(
    "  decode <file> -s <schema.mbs> [--json] Print the decoded value tree as JSON",
  )
  println(
    "  validate <file> -s <schema.mbs>        Decode and report pass/fail only",
  )
}

///|
struct Options {
  input : String?
  schema : String?
}

///|
/// `--json` is accepted (it is the CLI's documented flag for `decode`) but
/// has no effect: `decode` always renders JSON, since that is its only job.
fn parse_options(arguments : Array[String]) -> Options {
  let mut input = None
  let mut schema = None
  let mut index = 0
  while index < arguments.length() {
    let argument = arguments[index]
    if (argument == "-s" || argument == "--schema") &&
      index + 1 < arguments.length() {
      schema = Some(arguments[index + 1])
      index += 2
    } else if argument == "--json" {
      index += 1
    } else {
      if input is None {
        input = Some(argument)
      }
      index += 1
    }
  }
  Options::{ input, schema, }
}

///|
fn read_schema_document(path : String) -> @spec.Document raise Failure {
  let source = @fs.read_file_to_string(path) catch {
    @fs.IOError(message) => {
      println("ERROR: could not read schema \{path}: \{message}")
      raise Failure("could not read schema")
    }
  }
  match @spec.parse_document(source) {
    Ok(document) => document
    Err(message) => {
      println("ERROR: invalid schema \{path}: \{message}")
      raise Failure("invalid schema")
    }
  }
}

///|
fn read_binary(path : String) -> Bytes raise Failure {
  @fs.read_file_to_bytes(path) catch {
    @fs.IOError(message) => {
      println("ERROR: could not read \{path}: \{message}")
      raise Failure("could not read input")
    }
  }
}

///|
fn require(value : String?, flag_description : String) -> String raise Failure {
  match value {
    Some(text) => text
    None => {
      println("ERROR: missing \{flag_description}")
      print_usage()
      raise Failure("missing argument")
    }
  }
}

///|
fn report_decode_error(error : @spec.DecodeError) -> Unit {
  println("STRUCTURAL ERROR")
  println("")
  println(error.path)
  println("")
  println("offset:     0x\{error.offset.to_string(radix=16)}")
  println("expected:   \{error.expected} bytes")
  println("remaining:  \{error.remaining} bytes")
  println("reason:     \{error.reason}")
}

///|
fn main {
  let arguments = @env.args()
  let command = if arguments.length() > 1 { arguments[1] } else { "help" }
  let options = parse_options(
    if arguments.length() > 2 {
      arguments[2:].to_owned()
    } else {
      []
    },
  )
  try {
    match command {
      "help" | "--help" | "-h" => print_usage()
      "check" => {
        let schema_path = require(options.input, "schema path")
        let document = read_schema_document(schema_path)
        let root = document.root()
        println(
          "Schema valid: \{document.formats.length()} format(s), root \{root.name} (\{root.fields.length()} field(s))",
        )
      }
      "inspect" => {
        let input_path = require(options.input, "input file")
        let schema_path = require(options.schema, "-s <schema.mbs>")
        let document = read_schema_document(schema_path)
        let bytes = read_binary(input_path)
        match @spec.decode(document, bytes) {
          Ok(root) => println(@spec.render_tree(root))
          Err(error) => report_decode_error(error)
        }
      }
      "decode" => {
        let input_path = require(options.input, "input file")
        let schema_path = require(options.schema, "-s <schema.mbs>")
        let document = read_schema_document(schema_path)
        let bytes = read_binary(input_path)
        match @spec.decode(document, bytes) {
          Ok(root) => println(@spec.render_json(root))
          Err(error) => report_decode_error(error)
        }
      }
      "validate" => {
        let input_path = require(options.input, "input file")
        let schema_path = require(options.schema, "-s <schema.mbs>")
        let document = read_schema_document(schema_path)
        let bytes = read_binary(input_path)
        match @spec.decode(document, bytes) {
          Ok(_) =>
            println("VALID \{input_path} matches \{document.root().name}")
          Err(error) => report_decode_error(error)
        }
      }
      _ => {
        println("Unknown command: \{command}")
        print_usage()
      }
    }
  } catch {
    Failure(_) => ()
  }
}
