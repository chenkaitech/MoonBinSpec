///|
fn main {
  let source =
    #|format SensorPacket endian little {
    #|  magic : u16
    #|  version : u8
    #|  payload_len : u16
    #|  payload : bytes[payload_len]
    #|}
  match @spec.parse_schema(source) {
    Err(message) => println("Schema error: \{message}")
    Ok(schema) =>
      match @spec.decode(schema, b"\x55\xAA\x01\x03\x00\x10\x20\x30") {
        Ok(nodes) => println(@spec.render_tree(schema, nodes))
        Err(error) => {
          println("ERROR \{error.path}")
          println("offset: 0x\{error.offset.to_string(radix=16)}")
          println("expected: \{error.expected} bytes")
          println("remaining: \{error.remaining} bytes")
          println("reason: \{error.reason}")
        }
      }
  }
}
