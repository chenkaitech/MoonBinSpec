///|
fn decode_source(
  source : String,
  bytes : Bytes,
) -> Result[Node, DecodeError] raise Failure {
  let document = match parse_document(source) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  decode(document, bytes)
}

///|
fn object_fields(node : Node) -> Array[Node] raise Failure {
  match node.value {
    Object(fields) => fields
    _ => fail("expected an object node")
  }
}

///|
test "schema parsing and big endian decoding" {
  let source =
    #|format Packet endian big {
    #|  length : u16
    #|  payload : bytes[length]
    #|}
  let root = match decode_source(source, b"\x00\x03\xAA\xBB\xCC") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  let fields = object_fields(root)
  assert_eq(fields.length(), 2)
  assert_eq(fields[0].offset, 0)
  assert_eq(fields[1].length, 3)
  assert_true(fields[0].value is UInt(3))
}

///|
test "little endian decoding" {
  let source = "format Sample endian little {\nvalue : u32\n}"
  let root = match decode_source(source, b"\x78\x56\x34\x12") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  assert_true(object_fields(root)[0].value is UInt(0x12345678UL))
}

///|
test "signed integers sign-extend correctly" {
  let source = "format Sample endian big {\nvalue : i16\n}"
  let root = match decode_source(source, b"\xFF\xFB") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  assert_true(object_fields(root)[0].value is Int(-5L))
}

///|
test "ascii fields decode as text" {
  let source = "format Sample endian big {\nkind : ascii[4]\n}"
  let root = match decode_source(source, b"IHDR") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  assert_true(object_fields(root)[0].value is Text("IHDR"))
}

///|
test "truncated input reports field location" {
  let source = "format Image endian big {\ndata : bytes[8]\n}"
  match decode_source(source, b"\x00\x01") {
    Err(error) => {
      assert_eq(error.path, "Image.data")
      assert_eq(error.expected, 8)
      assert_eq(error.remaining, 2)
    }
    Ok(_) => fail("expected a truncated input error")
  }
}

///|
test "json renderer preserves field offsets" {
  let source = "format Flag endian big {\nvalue : u8\n}"
  let root = match decode_source(source, b"\x2A") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  assert_eq(
    render_json(root),
    "{\"name\":\"Flag\",\"offset\":0,\"length\":1,\"value\":{\"value\":{\"name\":\"value\",\"offset\":0,\"length\":1,\"value\":42}}}",
  )
}

///|
test "document AST retains multiple format declarations" {
  let document = match
    parse_document(
      "format Header endian big {\nmagic : u16\n}\nformat Body endian little {\nvalue : u8\n}",
    ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(document.formats.length(), 2)
  assert_eq(document.formats[0].name, "Header")
  assert_true(document.formats[1].endian is Little)
  assert_eq(document.root().name, "Body")
}

///|
test "schema parser rejects invalid field placement and lengths" {
  assert_true(parse_schema("value : u8") is Err(_))
  assert_true(
    parse_schema("format Invalid endian big {\ndata : bytes[]\n}") is Err(_),
  )
  assert_true(
    parse_schema(
      "format Invalid endian big {\ndata : bytes[length]\nlength : u8\n}",
    )
    is Err(_),
  )
}

///|
test "schema parser rejects duplicate field names" {
  assert_true(
    parse_schema("format Invalid endian big {\nvalue : u8\nvalue : u16\n}")
    is Err(_),
  )
}

///|
test "nested struct fields decode recursively" {
  let source =
    #|format Point endian big {
    #|  x : u8
    #|  y : u8
    #|}
    #|format Line endian big {
    #|  start : Point
    #|  stop  : Point
    #|}
  let root = match decode_source(source, b"\x01\x02\x03\x04") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  let fields = object_fields(root)
  assert_eq(fields.length(), 2)
  assert_eq(fields[1].offset, 2)
  let stop_fields = object_fields(fields[1])
  assert_true(stop_fields[0].value is UInt(3))
  assert_true(stop_fields[1].value is UInt(4))
}

///|
test "fixed-count arrays of a nested struct decode in order" {
  let source =
    #|format Sample endian big {
    #|  value : u8
    #|}
    #|format Container endian big {
    #|  count  : u8
    #|  values : Sample[count]
    #|}
  let root = match decode_source(source, b"\x03\x0A\x0B\x0C") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  let fields = object_fields(root)
  match fields[1].value {
    Value::Array(items) => {
      assert_eq(items.length(), 3)
      assert_eq(items[2].offset, 3)
      assert_true(object_fields(items[0])[0].value is UInt(10))
    }
    _ => fail("expected an array field")
  }
}

///|
test "until-eof arrays consume all remaining bytes" {
  let source =
    #|format Chunk endian big {
    #|  tag : u8
    #|}
    #|format Stream endian big {
    #|  chunks : Chunk[*] until eof
    #|}
  let root = match decode_source(source, b"\x01\x02\x03") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  match object_fields(root)[0].value {
    Value::Array(items) => assert_eq(items.length(), 3)
    _ => fail("expected an array field")
  }
}

///|
test "expect validates a constant field" {
  let source =
    #|format Signature endian big {
    #|  magic : bytes[4] expect hex("89504E47")
    #|}
  assert_true(decode_source(source, b"\x89PNG") is Ok(_))
  match decode_source(source, b"\x00\x00\x00\x00") {
    Err(error) => assert_eq(error.path, "Signature.magic")
    Ok(_) => fail("expected a constant mismatch error")
  }
}

///|
test "schema parser rejects unknown struct references" {
  assert_true(
    parse_document("format Root endian big {\nchild : Missing\n}") is Err(_),
  )
}

///|
test "schema parser rejects an array declared with '[*]' but no 'until eof'" {
  assert_true(
    parse_schema("format Bad endian big {\nitems : Thing[*]\n}") is Err(_),
  )
}

///|
test "schema parser requires modifiers on the same line as their field" {
  // `expect` / `until eof` are single-line suffixes in this grammar, unlike
  // the two-line illustrative examples in the design notes; a modifier on
  // its own line is simply unexpected syntax.
  assert_true(
    parse_schema("format Bad endian big {\nvalue : u8\n    until eof\n}")
    is Err(_),
  )
  assert_true(
    parse_schema(
      "format Bad endian big {\nvalue : u32\n    expect hex(\"00000000\")\n}",
    )
    is Err(_),
  )
}
