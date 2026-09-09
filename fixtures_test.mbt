///|
/// Golden-fixture tests: real schema files decoding real (and deliberately
/// corrupted) binary files from `fixtures/`, exercising the full
/// schema-parse -> decode -> value-tree pipeline the CLI and web Inspector
/// both build on.

///|
fn load_document(path : String) -> Document raise {
  match parse_document(@fs.read_file_to_string(path)) {
    Ok(value) => value
    Err(message) => fail(message)
  }
}

///|
test "PNG fixture decodes into a signature and three well-known chunks" {
  let document = load_document("schemas/png.mbs")
  let bytes = @fs.read_file_to_bytes("fixtures/sample.png")
  let root = match decode(document, bytes) {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  let fields = object_fields(root)
  assert_true(fields[0].value is Value::Bytes(_))
  match fields[1].value {
    Value::Array(chunks) => {
      assert_eq(chunks.length(), 3)
      assert_true(object_fields(chunks[0])[1].value is Text("IHDR"))
      assert_true(object_fields(chunks[1])[1].value is Text("IDAT"))
      assert_true(object_fields(chunks[2])[1].value is Text("IEND"))
    }
    _ => fail("expected a chunks array")
  }
}

///|
test "corrupted PNG fixture reports a precise structural error" {
  let document = load_document("schemas/png.mbs")
  let bytes = @fs.read_file_to_bytes("fixtures/corrupt.png")
  match decode(document, bytes) {
    Err(error) => {
      assert_eq(error.path, "PNG.chunks[1].data")
      assert_eq(error.reason, "field length exceeds remaining input")
    }
    Ok(_) => fail("expected the corrupted fixture to fail decoding")
  }
}

///|
test "WAV fixture decodes into fmt and data chunks" {
  let document = load_document("schemas/wav.mbs")
  let bytes = @fs.read_file_to_bytes("fixtures/sample.wav")
  let root = match decode(document, bytes) {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  match object_fields(root)[3].value {
    Value::Array(chunks) => {
      assert_eq(chunks.length(), 2)
      assert_true(object_fields(chunks[0])[0].value is Text("fmt "))
      assert_true(object_fields(chunks[1])[0].value is Text("data"))
    }
    _ => fail("expected a chunks array")
  }
}

///|
test "corrupted WAV fixture reports a precise structural error" {
  let document = load_document("schemas/wav.mbs")
  let bytes = @fs.read_file_to_bytes("fixtures/corrupt.wav")
  match decode(document, bytes) {
    Err(error) => {
      assert_eq(error.path, "WAV.chunks[1].data")
      assert_eq(error.reason, "field length exceeds remaining input")
    }
    Ok(_) => fail("expected the corrupted fixture to fail decoding")
  }
}

///|
test "sensor schema decodes the real fixture" {
  let document = load_document("schemas/sensor.mbs")
  let bytes = @fs.read_file_to_bytes("fixtures/sample.sensor")
  let root = match decode(document, bytes) {
    Ok(value) => value
    Err(error) => fail(error.reason)
  }
  let fields = object_fields(root)
  assert_true(fields[0].value is UInt(0xAA55UL))
  assert_true(fields[3].value is Value::Bytes(b"\x10\x20\x30"))
}
