///|
/// The decoder engine: turns a `Document` (schema AST) plus raw bytes into a
/// source-mapped value tree. Pure MoonBit, no file or platform dependency,
/// so the same core runs on Native, Wasm, and JS.
///
/// Assumes `document` was produced by `parse_document`/`parse_schema`, which
/// guarantee every `Struct`/`StructRef` name resolves to another format in
/// the same document — a hand-built `Document` that skips that check can
/// make `document.find(target).unwrap()` panic below.

///|
pub enum Value {
  UInt(UInt64)
  Int(Int64)
  Text(String)
  Bytes(Bytes)
  Array(Array[Node])
  Object(Array[Node])
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
const MAX_DEPTH = 64

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
/// Renders `length` bytes starting at `offset` as an uppercase hex string.
pub fn to_hex(bytes : Bytes, offset : Int, length : Int) -> String {
  let output = StringBuilder()
  for index in offset..<(offset + length) {
    let value = bytes[index].to_int()
    output.write_char(hex_digit(value >> 4))
    output.write_char(hex_digit(value & 15))
  }
  output.to_string()
}

///|
fn slice_bytes(bytes : Bytes, offset : Int, length : Int) -> Bytes {
  Bytes::from_array(bytes.view(start=offset, end=offset + length).to_array())
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
fn signed_value(
  bytes : Bytes,
  offset : Int,
  length : Int,
  endian : Endian,
) -> Int64 {
  let raw = unsigned_value(bytes, offset, length, endian)
  if length >= 8 {
    raw.reinterpret_as_int64()
  } else {
    let sign_bit : UInt64 = 1UL << (length * 8 - 1)
    if (raw & sign_bit) != 0UL {
      let fill : UInt64 = 0xFFFFFFFFFFFFFFFFUL << (length * 8)
      (raw | fill).reinterpret_as_int64()
    } else {
      raw.reinterpret_as_int64()
    }
  }
}

///|
/// Decodes ASCII/UTF-8-ish bytes into text for display; invalid bytes are
/// preserved as the U+FFFD replacement character rather than failing decode,
/// since text fields are display data, not protocol integers.
fn decode_text(bytes : Bytes, offset : Int, length : Int) -> String {
  let output = StringBuilder()
  for index in offset..<(offset + length) {
    let value = bytes[index].to_int()
    if value >= 32 && value < 127 {
      output.write_char(value.unsafe_to_char())
    } else {
      output.write_char('�')
    }
  }
  output.to_string()
}

///|
fn lookup_uint(siblings : Array[Node], name : String) -> Result[Int, String] {
  for node in siblings {
    if node.name == name {
      match node.value {
        UInt(value) => return Ok(value.to_int())
        _ =>
          return Err("reference must name an unsigned integer field: \{name}")
      }
    }
  }
  Err("reference must name an earlier field: \{name}")
}

///|
fn scalar_size(
  scalar : ScalarType,
  siblings : Array[Node],
) -> Result[Int, String] {
  match scalar {
    I8 | U8 => Ok(1)
    I16 | U16 => Ok(2)
    I32 | U32 => Ok(4)
    I64 | U64 => Ok(8)
    Bytes(size) | Ascii(size) => Ok(size)
    BytesFrom(name) | AsciiFrom(name) => lookup_uint(siblings, name)
  }
}

///|
fn decode_scalar(
  name : String,
  scalar : ScalarType,
  bytes : Bytes,
  offset : Int,
  endian : Endian,
  path : String,
  siblings : Array[Node],
) -> Result[Node, DecodeError] {
  let size = match scalar_size(scalar, siblings) {
    Ok(value) => value
    Err(reason) =>
      return Err(DecodeError::{
        path,
        offset,
        expected: 0,
        remaining: bytes.length() - offset,
        reason,
      })
  }
  let remaining = bytes.length() - offset
  if size < 0 || size > remaining {
    return Err(DecodeError::{
      path,
      offset,
      expected: size,
      remaining,
      reason: "field length exceeds remaining input",
    })
  }
  let value = match scalar {
    U8 | U16 | U32 | U64 => UInt(unsigned_value(bytes, offset, size, endian))
    I8 | I16 | I32 | I64 => Int(signed_value(bytes, offset, size, endian))
    Ascii(_) | AsciiFrom(_) => Text(decode_text(bytes, offset, size))
    Bytes(_) | BytesFrom(_) => Value::Bytes(slice_bytes(bytes, offset, size))
  }
  Ok(Node::{ name, value, offset, length: size, })
}

///|
fn decode_fields(
  document : Document,
  fields : Array[Field],
  bytes : Bytes,
  start_offset : Int,
  path : String,
  endian : Endian,
  depth : Int,
) -> Result[(Array[Node], Int), DecodeError] {
  if depth > MAX_DEPTH {
    return Err(DecodeError::{
      path,
      offset: start_offset,
      expected: 0,
      remaining: bytes.length() - start_offset,
      reason: "maximum nesting depth exceeded (possible recursive schema)",
    })
  }
  let mut offset = start_offset
  let nodes : Array[Node] = []
  for field in fields {
    let field_path = "\{path}.\{field.name}"
    match field.kind {
      Scalar(scalar) => {
        let node = match
          decode_scalar(
            field.name,
            scalar,
            bytes,
            offset,
            endian,
            field_path,
            nodes,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match field.expect {
          Some(ExpectHex(expected_hex)) => {
            let actual_hex = to_hex(bytes, node.offset, node.length)
            if actual_hex != expected_hex {
              return Err(DecodeError::{
                path: field_path,
                offset: node.offset,
                expected: node.length,
                remaining: bytes.length() - node.offset,
                reason: "constant mismatch: expected 0x\{expected_hex}, got 0x\{actual_hex}",
              })
            }
          }
          None => ()
        }
        offset = node.offset + node.length
        nodes.push(node)
      }
      Struct(target) => {
        let sub_schema = document.find(target).unwrap()
        let (children, end_offset) = match
          decode_fields(
            document,
            sub_schema.fields,
            bytes,
            offset,
            field_path,
            sub_schema.endian,
            depth + 1,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        nodes.push(Node::{
          name: field.name,
          value: Object(children),
          offset,
          length: end_offset - offset,
        })
        offset = end_offset
      }
      Array(element, repeat) => {
        let (children, end_offset) = match
          decode_array(
            document, element, repeat, bytes, offset, field_path, endian, nodes,
            depth,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        nodes.push(Node::{
          name: field.name,
          value: Value::Array(children),
          offset,
          length: end_offset - offset,
        })
        offset = end_offset
      }
    }
  }
  Ok((nodes, offset))
}

///|
fn decode_element(
  document : Document,
  element : ElementType,
  bytes : Bytes,
  offset : Int,
  label : String,
  path : String,
  endian : Endian,
  depth : Int,
) -> Result[Node, DecodeError] {
  match element {
    Prim(scalar) =>
      decode_scalar(label, scalar, bytes, offset, endian, path, [])
    StructRef(target) => {
      let sub_schema = document.find(target).unwrap()
      let (children, end_offset) = match
        decode_fields(
          document,
          sub_schema.fields,
          bytes,
          offset,
          path,
          sub_schema.endian,
          depth + 1,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(Node::{
        name: label,
        value: Object(children),
        offset,
        length: end_offset - offset,
      })
    }
  }
}

///|
fn decode_array(
  document : Document,
  element : ElementType,
  repeat : Repeat,
  bytes : Bytes,
  start_offset : Int,
  path : String,
  endian : Endian,
  siblings : Array[Node],
  depth : Int,
) -> Result[(Array[Node], Int), DecodeError] {
  let mut offset = start_offset
  let nodes : Array[Node] = []
  match repeat {
    Fixed(_) | FixedRef(_) => {
      let count = match repeat {
        Fixed(value) => value
        FixedRef(name) =>
          match lookup_uint(siblings, name) {
            Ok(value) => value
            Err(reason) =>
              return Err(DecodeError::{
                path,
                offset,
                expected: 0,
                remaining: bytes.length() - offset,
                reason,
              })
          }
        UntilEof => 0
      }
      for index in 0..<count {
        let element_path = "\{path}[\{index}]"
        let node = match
          decode_element(
            document,
            element,
            bytes,
            offset,
            "[\{index}]",
            element_path,
            endian,
            depth,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        offset = node.offset + node.length
        nodes.push(node)
      }
    }
    UntilEof => {
      let mut index = 0
      while offset < bytes.length() {
        let element_path = "\{path}[\{index}]"
        let node = match
          decode_element(
            document,
            element,
            bytes,
            offset,
            "[\{index}]",
            element_path,
            endian,
            depth,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        offset = node.offset + node.length
        nodes.push(node)
        index += 1
      }
    }
  }
  Ok((nodes, offset))
}

///|
/// Decodes `bytes` against `schema` (looked up from `document` so nested
/// struct references resolve), returning the root node as a `Value::Object`.
pub fn decode_format(
  document : Document,
  schema : Schema,
  bytes : Bytes,
) -> Result[Node, DecodeError] {
  let (children, end_offset) = match
    decode_fields(
      document,
      schema.fields,
      bytes,
      0,
      schema.name,
      schema.endian,
      0,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(Node::{
    name: schema.name,
    value: Object(children),
    offset: 0,
    length: end_offset,
  })
}

///|
/// Decodes `bytes` against the document's root format (the last format
/// declared in the schema source).
pub fn decode(document : Document, bytes : Bytes) -> Result[Node, DecodeError] {
  decode_format(document, document.root(), bytes)
}
