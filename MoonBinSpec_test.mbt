///|
test "schema parsing and big endian decoding" {
  let source =
    #|format Packet endian big {
    #|  length : u16
    #|  payload : bytes[length]
    #|}
  let schema = match parse_schema(source) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let nodes = match decode(schema, b"\x00\x03\xAA\xBB\xCC") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  assert_eq(nodes.length(), 2)
  assert_eq(nodes[0].offset, 0)
  assert_eq(nodes[1].length, 3)
  assert_true(nodes[0].value is Unsigned(3))
}

///|
test "little endian decoding" {
  let schema = match
    parse_schema("format Sample endian little {\nvalue : u32\n}") {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let nodes = match decode(schema, b"\x78\x56\x34\x12") {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  assert_true(nodes[0].value is Unsigned(0x12345678UL))
}

///|
test "truncated input reports field location" {
  let schema = match
    parse_schema("format Image endian big {\ndata : bytes[8]\n}") {
    Ok(value) => value
    Err(message) => fail(message)
  }
  match decode(schema, b"\x00\x01") {
    Err(error) => {
      assert_eq(error.path, "Image.data")
      assert_eq(error.expected, 8)
      assert_eq(error.remaining, 2)
    }
    Ok(_) => fail("expected a truncated input error")
  }
}
