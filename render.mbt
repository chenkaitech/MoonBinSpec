///|
/// Renderers turn a decoded `Node` tree into human- or machine-readable
/// output. They only depend on the value tree, never on file or platform
/// APIs, so the same renderers work from Native, Wasm, and JS.

///|
fn preview_value(value : Value) -> String {
  match value {
    UInt(number) => number.to_string()
    Int(number) => number.to_string()
    Text(text) => "\"\{text}\""
    Value::Bytes(raw) =>
      if raw.length() == 0 {
        "0x"
      } else {
        "0x\{to_hex(raw, 0, raw.length())}"
      }
    Value::Array(children) => "[\{children.length()} item(s)]"
    Object(_) => "{...}"
  }
}

///|
fn render_node(output : StringBuilder, node : Node, indent : String) -> Unit {
  match node.value {
    Value::Array(children) => {
      output.write_string(
        "\{indent}|- \{node.name}  [offset 0x\{node.offset.to_string(radix=16)}, length \{node.length}]\n",
      )
      let child_indent = indent + "   "
      for child in children {
        render_node(output, child, child_indent)
      }
    }
    Object(children) => {
      output.write_string(
        "\{indent}|- \{node.name}  [offset 0x\{node.offset.to_string(radix=16)}, length \{node.length}]\n",
      )
      let child_indent = indent + "   "
      for child in children {
        render_node(output, child, child_indent)
      }
    }
    other =>
      output.write_string(
        "\{indent}|- \{node.name}: \{preview_value(other)}  [offset 0x\{node.offset.to_string(radix=16)}, length \{node.length}]\n",
      )
  }
}

///|
/// Renders a decoded value tree as a concise inspector view suitable for
/// the native CLI.
pub fn render_tree(root : Node) -> String {
  let output = StringBuilder()
  output.write_string("\{root.name}\n")
  match root.value {
    Object(children) | Value::Array(children) =>
      for child in children {
        render_node(output, child, "")
      }
    other => output.write_string("|- \{preview_value(other)}\n")
  }
  output.to_string()
}

///|
pub fn json_escape(text : String) -> String {
  let output = StringBuilder()
  for character in text {
    match character {
      '"' => output.write_string("\\\"")
      '\\' => output.write_string("\\\\")
      '\n' => output.write_string("\\n")
      '\r' => output.write_string("\\r")
      '\t' => output.write_string("\\t")
      _ => output.write_char(character)
    }
  }
  output.to_string()
}

///|
fn write_json_value(output : StringBuilder, value : Value) -> Unit {
  match value {
    UInt(number) => output.write_string(number.to_string())
    Int(number) => output.write_string(number.to_string())
    Text(text) => output.write_string("\"\{json_escape(text)}\"")
    Value::Bytes(raw) =>
      output.write_string("\"0x\{to_hex(raw, 0, raw.length())}\"")
    Value::Array(children) => write_json_array(output, children)
    Object(children) => write_json_fields(output, children)
  }
}

///|
fn write_json_node(output : StringBuilder, node : Node) -> Unit {
  output.write_string(
    "{\"name\":\"\{json_escape(node.name)}\",\"offset\":\{node.offset},\"length\":\{node.length},\"value\":",
  )
  write_json_value(output, node.value)
  output.write_string("}")
}

///|
fn write_json_array(output : StringBuilder, nodes : Array[Node]) -> Unit {
  output.write_string("[")
  for index, node in nodes {
    if index > 0 {
      output.write_string(",")
    }
    write_json_node(output, node)
  }
  output.write_string("]")
}

///|
fn write_json_fields(output : StringBuilder, nodes : Array[Node]) -> Unit {
  output.write_string("{")
  for index, node in nodes {
    if index > 0 {
      output.write_string(",")
    }
    output.write_string("\"\{json_escape(node.name)}\":")
    write_json_node(output, node)
  }
  output.write_string("}")
}

///|
/// Renders a decoded value tree as JSON while preserving byte source
/// mapping (`offset` / `length`) on every node.
pub fn render_json(root : Node) -> String {
  let output = StringBuilder()
  write_json_node(output, root)
  output.to_string()
}
