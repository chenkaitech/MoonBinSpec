///|
/// A compact declarative binary format toolkit.
pub enum Endian {
  Little
  Big
} derive(Eq, Debug)

///|
pub enum FieldType {
  U8
  U16
  U32
  Bytes(Int)
  Ascii(Int)
  BytesFrom(String)
  AsciiFrom(String)
} derive(Eq, Debug)

///|
pub struct Field {
  name : String
  kind : FieldType
} derive(Eq, Debug)

///|
pub struct Schema {
  name : String
  endian : Endian
  fields : Array[Field]
} derive(Eq, Debug)

///|
pub enum Value {
  Unsigned(UInt64)
  Hex(String)
} derive(Eq, Debug)

///|
pub struct Node {
  name : String
  value : Value
  offset : Int
  length : Int
} derive(Eq, Debug)

///|
pub struct DecodeError {
  path : String
  offset : Int
  expected : Int
  remaining : Int
  reason : String
} derive(Eq, Debug)

///|
fn trim(value : StringView) -> String {
  value.trim().to_owned()
}

///|
fn parse_endian(value : String) -> Endian? {
  match value {
    "little" => Some(Little)
    "big" => Some(Big)
    _ => None
  }
}

///|
fn parse_size(value : String) -> Int? {
  let mut result = 0
  for character in value {
    if character < '0' || character > '9' {
      return None
    }
    result = result * 10 + (character.to_int() - '0'.to_int())
  }
  Some(result)
}

///|
fn parse_field_type(value : String) -> FieldType? {
  let source = trim(value)
  match source {
    "u8" => Some(U8)
    "u16" => Some(U16)
    "u32" => Some(U32)
    _ => {
      let is_bytes = source.has_prefix("bytes[") && source.has_suffix("]")
      let is_ascii = source.has_prefix("ascii[") && source.has_suffix("]")
      if !is_bytes && !is_ascii {
        None
      } else {
        let prefix = if is_bytes { 6 } else { 6 }
        let inner = source[prefix:source.length() - 1].to_owned()
        match parse_size(inner) {
          Some(size) =>
            if is_bytes {
              Some(Bytes(size))
            } else {
              Some(Ascii(size))
            }
          None =>
            if is_bytes {
              Some(BytesFrom(inner))
            } else {
              Some(AsciiFrom(inner))
            }
        }
      }
    }
  }
}

///|
/// Parses the intentionally small V1 schema language.
pub fn parse_schema(source : String) -> Result[Schema, String] {
  let lines = source.split("\n")
  let mut name = ""
  let mut endian = Big
  let fields : Array[Field] = []
  for raw_line in lines {
    let line = trim(raw_line)
    if line.has_prefix("format ") {
      let words = line.split(" ").collect()
      if words.length() < 4 || words[2] != "endian" {
        return Err("invalid format declaration")
      }
      name = words[1].to_owned()
      match parse_endian(words[3].to_owned()) {
        Some(value) => endian = value
        None => return Err("endian must be big or little")
      }
    } else if line.contains(":") {
      let pair = line.split(":").collect()
      if pair.length() != 2 {
        return Err("invalid field declaration: \{line}")
      }
      let field_name = trim(pair[0])
      match parse_field_type(pair[1].to_owned()) {
        Some(kind) => fields.push(Field::{ name: field_name, kind, })
        None => return Err("unsupported field type: \\{trim(pair[1])}")
      }
    }
  }
  if name == "" {
    Err("schema is missing a format declaration")
  } else if fields.length() == 0 {
    Err("schema must declare at least one field")
  } else {
    Ok(Schema::{ name, endian, fields, })
  }
}

///|
fn field_size(kind : FieldType, nodes : Array[Node]) -> Int? {
  match kind {
    U8 => Some(1)
    U16 => Some(2)
    U32 => Some(4)
    Bytes(size) | Ascii(size) => Some(size)
    BytesFrom(name) | AsciiFrom(name) => {
      for node in nodes {
        if node.name == name {
          match node.value {
            Unsigned(value) => return Some(value.to_int())
            Hex(_) => return None
          }
        }
      }
      None
    }
  }
}

///|
fn hex_digit(value : Int) -> Char {
  match value {
    0 => '0'
    1 => '1'
    2 => '2'
    3 => '3'
    4 => '4'
    5 => '5'
    6 => '6'
    7 => '7'
    8 => '8'
    9 => '9'
    10 => 'A'
    11 => 'B'
    12 => 'C'
    13 => 'D'
    14 => 'E'
    _ => 'F'
  }
}

///|
fn to_hex(bytes : Bytes, offset : Int, length : Int) -> String {
  let output = StringBuilder()
  for index in offset..<(offset + length) {
    let value = bytes[index].to_int()
    output.write_char(hex_digit(value >> 4))
    output.write_char(hex_digit(value & 15))
  }
  output.to_string()
}

///|
fn unsigned_value(
  bytes : Bytes,
  offset : Int,
  length : Int,
  endian : Endian,
) -> UInt64 {
  let mut result : UInt64 = 0
  match endian {
    Big =>
      for index in offset..<(offset + length) {
        result = (result << 8) | bytes[index].to_int().to_uint64()
      }
    Little =>
      for index in 0..<length {
        result = result |
          (bytes[offset + index].to_int().to_uint64() << (index * 8))
      }
  }
  result
}

///|
/// Decodes bytes into a field tree with source offsets and lengths.
pub fn decode(
  schema : Schema,
  bytes : Bytes,
) -> Result[Array[Node], DecodeError] {
  let mut offset = 0
  let nodes : Array[Node] = []
  for field in schema.fields {
    let size = match field_size(field.kind, nodes) {
      Some(value) if value >= 0 => value
      _ =>
        return Err(DecodeError::{
          path: "\{schema.name}.\{field.name}",
          offset,
          expected: 0,
          remaining: bytes.length() - offset,
          reason: "length reference must name an earlier unsigned field",
        })
    }
    let remaining = bytes.length() - offset
    if size > remaining {
      return Err(DecodeError::{
        path: "\{schema.name}.\{field.name}",
        offset,
        expected: size,
        remaining,
        reason: "field length exceeds remaining input",
      })
    }
    let value = match field.kind {
      U8 | U16 | U32 =>
        Unsigned(unsigned_value(bytes, offset, size, schema.endian))
      Bytes(_) | Ascii(_) | BytesFrom(_) | AsciiFrom(_) =>
        Hex(to_hex(bytes, offset, size))
    }
    nodes.push(Node::{ name: field.name, value, offset, length: size, })
    offset += size
  }
  Ok(nodes)
}

///|
/// Renders a concise inspector view suitable for the native CLI.
pub fn render_tree(schema : Schema, nodes : Array[Node]) -> String {
  let output = StringBuilder()
  output.write_string("\{schema.name}\n")
  for node in nodes {
    let value = match node.value {
      Unsigned(number) => number.to_string()
      Hex(hex) => "0x\{hex}"
    }
    output.write_string(
      "|- \{node.name}: \{value}  [offset 0x\{node.offset.to_string(radix=16)}, length \{node.length}]\n",
    )
  }
  output.to_string()
}
