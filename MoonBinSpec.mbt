///|
/// A compact declarative binary format toolkit.
///
/// This file defines the `.mbs` schema language: its AST and the line-based
/// parser that turns schema source text into a `Document`. Decoding (schema
/// AST + bytes -> value tree) lives in `decoder.mbt`; rendering the value
/// tree (terminal / JSON) lives in `render.mbt`.
pub enum Endian {
  Little
  Big
} derive(Eq, Debug)

///|
/// Primitive, non-recursive field types. These always consume a statically
/// or dynamically known number of bytes and never reference another format.
pub enum ScalarType {
  I8
  U8
  I16
  U16
  I32
  U32
  I64
  U64
  Bytes(Int)
  Ascii(Int)
  BytesFrom(String)
  AsciiFrom(String)
} derive(Eq, Debug)

///|
/// The element type of a repeated (`[...]`) field: either a scalar, or a
/// reference to another named format (nested struct).
pub enum ElementType {
  Prim(ScalarType)
  StructRef(String)
} derive(Eq, Debug)

///|
/// How many times an array field repeats.
pub enum Repeat {
  Fixed(Int)
  FixedRef(String)
  UntilEof
} derive(Eq, Debug)

///|
pub enum FieldType {
  Scalar(ScalarType)
  Struct(String)
  Array(ElementType, Repeat)
} derive(Eq, Debug)

///|
/// A constant-value assertion attached to a field, e.g.
/// `signature : bytes[8] expect hex("89504E470D0A1A0A")`.
pub enum Expectation {
  ExpectHex(String)
} derive(Eq, Debug)

///|
pub struct Field {
  name : String
  kind : FieldType
  expect : Expectation?
} derive(Eq, Debug)

///|
pub struct Schema {
  name : String
  endian : Endian
  fields : Array[Field]
} derive(Eq, Debug)

///|
/// A schema source file containing one or more named formats. By convention
/// the *last* format declared in the document is the root format used by
/// `decode`; earlier formats exist to be referenced as nested structs.
pub struct Document {
  formats : Array[Schema]
} derive(Eq, Debug)

///|
fn trim(value : StringView) -> String {
  value.trim().to_owned()
}

///|
fn strip_comment(line : String) -> String {
  match line.find("//") {
    Some(index) => trim(line[0:index])
    None => line
  }
}

///|
fn is_ident_start(character : Char) -> Bool {
  (character >= 'a' && character <= 'z') ||
  (character >= 'A' && character <= 'Z') ||
  character == '_'
}

///|
fn is_ident_char(character : Char) -> Bool {
  is_ident_start(character) || (character >= '0' && character <= '9')
}

///|
fn is_identifier(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for index, character in value {
    if index == 0 {
      if !is_ident_start(character) {
        return false
      }
    } else if !is_ident_char(character) {
      return false
    }
  }
  true
}

///|
fn is_digits(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for character in value {
    if character < '0' || character > '9' {
      return false
    }
  }
  true
}

///|
fn is_hex_digits(value : String) -> Bool {
  if value.length() == 0 || value.length() % 2 != 0 {
    return false
  }
  for character in value {
    let is_digit = character >= '0' && character <= '9'
    let is_upper = character >= 'A' && character <= 'F'
    let is_lower = character >= 'a' && character <= 'f'
    if !is_digit && !is_upper && !is_lower {
      return false
    }
  }
  true
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
  if !is_digits(value) {
    return None
  }
  let mut result = 0
  for character in value {
    result = result * 10 + (character.to_int() - '0'.to_int())
  }
  Some(result)
}

///|
fn parse_scalar_head(head : String) -> ScalarType? {
  match head {
    "i8" => Some(I8)
    "u8" => Some(U8)
    "i16" => Some(I16)
    "u16" => Some(U16)
    "i32" => Some(I32)
    "u32" => Some(U32)
    "i64" => Some(I64)
    "u64" => Some(U64)
    _ => None
  }
}

///|
/// Splits `head[inner]` into `(head, inner)`. Returns `None` if the
/// expression does not have exactly one well-formed bracket pair at the end.
fn split_brackets(raw : String) -> (String, String)? {
  if !raw.has_suffix("]") {
    return None
  }
  match raw.find("[") {
    Some(open) => {
      let head = trim(raw[0:open])
      let inner = trim(raw[open + 1:raw.length() - 1])
      Some((head, inner))
    }
    None => None
  }
}

///|
/// Parses the type expression that appears after `name :` (modifiers such as
/// `expect ...` / `until eof` are stripped by the caller beforehand).
fn parse_field_type(raw : String) -> FieldType? {
  let source = trim(raw)
  match split_brackets(source) {
    None =>
      match parse_scalar_head(source) {
        Some(scalar) => Some(Scalar(scalar))
        None => if is_identifier(source) { Some(Struct(source)) } else { None }
      }
    Some((head, inner)) =>
      if head == "bytes" || head == "ascii" {
        match parse_size(inner) {
          Some(size) =>
            Some(
              Scalar(if head == "bytes" { Bytes(size) } else { Ascii(size) }),
            )
          None =>
            if is_identifier(inner) {
              Some(
                Scalar(
                  if head == "bytes" {
                    BytesFrom(inner)
                  } else {
                    AsciiFrom(inner)
                  },
                ),
              )
            } else {
              None
            }
        }
      } else {
        let element = match parse_scalar_head(head) {
          Some(scalar) => Prim(scalar)
          None =>
            if is_identifier(head) {
              StructRef(head)
            } else {
              return None
            }
        }
        if inner == "*" {
          Some(Array(element, UntilEof))
        } else {
          match parse_size(inner) {
            Some(count) => Some(Array(element, Fixed(count)))
            None =>
              if is_identifier(inner) {
                Some(Array(element, FixedRef(inner)))
              } else {
                None
              }
          }
        }
      }
  }
}

///|
/// Splits a field's right-hand side into its type expression and an
/// optional trailing modifier (`expect hex("...")` or `until eof`).
fn split_modifier(raw : String) -> (String, String?) {
  let source = trim(raw)
  match source.find(" expect ") {
    Some(index) =>
      (trim(source[0:index]), Some(trim(source[index + 8:source.length()])))
    None =>
      if source.has_suffix(" until eof") {
        (trim(source[0:source.length() - 10]), Some("until eof"))
      } else {
        (source, None)
      }
  }
}

///|
fn parse_expect_hex(raw : String) -> String? {
  let source = trim(raw)
  if source.has_prefix("hex(\"") && source.has_suffix("\")") {
    let inner = source[5:source.length() - 2].to_owned()
    if is_hex_digits(inner) {
      Some(inner.to_upper())
    } else {
      None
    }
  } else {
    None
  }
}

///|
fn parse_field(line : String) -> Result[Field, String] {
  let pair = line.split(":").collect()
  if pair.length() != 2 {
    return Err("invalid field declaration: \{line}")
  }
  let field_name = trim(pair[0])
  if field_name == "" || !is_identifier(field_name) {
    return Err("invalid field name: \{trim(pair[0])}")
  }
  let (type_part, modifier) = split_modifier(pair[1].to_owned())
  let kind = match parse_field_type(type_part) {
    Some(value) => value
    None => return Err("unsupported field type: \{type_part}")
  }
  let is_until_eof = match kind {
    Array(_, UntilEof) => true
    _ => false
  }
  if is_until_eof && modifier != Some("until eof") {
    return Err("array declared with '[*]' must end with 'until eof': \{line}")
  }
  if !is_until_eof && modifier == Some("until eof") {
    return Err(
      "'until eof' may only follow an array declared with '[*]': \{line}",
    )
  }
  let expect = match modifier {
    None | Some("until eof") => None
    Some(clause) =>
      match kind {
        Scalar(Bytes(size)) | Scalar(Ascii(size)) =>
          match parse_expect_hex(clause) {
            Some(hex) =>
              if hex.length() != size * 2 {
                return Err(
                  "expect hex literal length does not match field size: \{line}",
                )
              } else {
                Some(ExpectHex(hex))
              }
            None => return Err("unsupported expect clause: \{clause}")
          }
        _ =>
          return Err(
            "'expect' is only supported on fixed-size bytes/ascii fields: \{line}",
          )
      }
  }
  Ok(Field::{ name: field_name, kind, expect, })
}

///|
/// Parses the intentionally small V1 schema language into a `Document`
/// containing every `format` block declared in `source`.
pub fn parse_document(source : String) -> Result[Document, String] {
  let lines = source.split("\n")
  let formats : Array[Schema] = []
  let mut in_format = false
  let mut name = ""
  let mut endian = Big
  let mut fields : Array[Field] = []
  for raw_line in lines {
    let line = strip_comment(trim(raw_line))
    if line == "" {
      continue
    } else if line.has_prefix("format ") {
      if in_format {
        return Err("a format block must be closed before another begins")
      }
      let words = line.split(" ").collect()
      if words.length() != 5 || words[2] != "endian" || words[4] != "{" {
        return Err("invalid format declaration: \{line}")
      }
      let format_name = words[1].to_owned()
      if !is_identifier(format_name) {
        return Err("invalid format name: \{format_name}")
      }
      for schema in formats {
        if schema.name == format_name {
          return Err("duplicate format name: \{format_name}")
        }
      }
      match parse_endian(words[3].to_owned()) {
        Some(value) => endian = value
        None => return Err("endian must be big or little")
      }
      name = format_name
      fields = []
      in_format = true
    } else if line == "}" {
      if !in_format {
        return Err("unexpected closing brace")
      }
      if fields.length() == 0 {
        return Err("format \{name} must declare at least one field")
      }
      for field in fields {
        match field.kind {
          Scalar(BytesFrom(reference))
          | Scalar(AsciiFrom(reference))
          | Array(_, FixedRef(reference)) =>
            match validate_reference(fields, field.name, reference) {
              Ok(_) => ()
              Err(message) => return Err(message)
            }
          _ => ()
        }
      }
      formats.push(Schema::{ name, endian, fields, })
      in_format = false
    } else if !in_format {
      return Err(
        "field or format declaration outside of a format block: \{line}",
      )
    } else if line.contains(":") {
      let field = match parse_field(line) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      for existing in fields {
        if existing.name == field.name {
          return Err("duplicate field name: \{field.name}")
        }
      }
      fields.push(field)
    } else {
      return Err("unexpected schema syntax: \{line}")
    }
  }
  if in_format {
    return Err("format \{name} is missing a closing brace")
  }
  if formats.length() == 0 {
    return Err("schema document must declare at least one format")
  }
  for schema in formats {
    for field in schema.fields {
      let referenced = match field.kind {
        Struct(target) => Some(target)
        Array(StructRef(target), _) => Some(target)
        _ => None
      }
      match referenced {
        Some(target) => {
          let mut found = false
          for candidate in formats {
            if candidate.name == target {
              found = true
            }
          }
          if !found {
            return Err(
              "\{schema.name}.\{field.name} references unknown format: \{target}",
            )
          }
        }
        None => ()
      }
    }
  }
  Ok(Document::{ formats, })
}

///|
fn validate_reference(
  fields : Array[Field],
  field_name : String,
  reference : String,
) -> Result[Unit, String] {
  let mut found = false
  for previous in fields {
    if previous.name == field_name {
      break
    }
    if previous.name == reference {
      match previous.kind {
        Scalar(U8) | Scalar(U16) | Scalar(U32) | Scalar(U64) => found = true
        _ =>
          return Err(
            "length/count reference must name an earlier unsigned integer field: \{reference}",
          )
      }
    }
  }
  if !found {
    Err("length/count reference must name an earlier field: \{reference}")
  } else {
    Ok(())
  }
}

///|
/// Parses a schema source that declares exactly one `format` block. Useful
/// for the CLI `check` command and for tests that do not need nested
/// references.
pub fn parse_schema(source : String) -> Result[Schema, String] {
  match parse_document(source) {
    Ok(document) =>
      if document.formats.length() != 1 {
        Err(
          "expected exactly one format declaration, found \{document.formats.length()}",
        )
      } else {
        Ok(document.formats[0])
      }
    Err(message) => Err(message)
  }
}

///|
/// The root format of a document: the last format declared, by convention.
pub fn Document::root(self : Document) -> Schema {
  self.formats[self.formats.length() - 1]
}

///|
fn Document::find(self : Document, name : String) -> Schema? {
  for schema in self.formats {
    if schema.name == name {
      return Some(schema)
    }
  }
  None
}
