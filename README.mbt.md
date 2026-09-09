# MoonBinSpec

Declarative binary format parsing, validation, and field inspection for MoonBit.

MoonBinSpec turns a small `.mbs` schema into a pure MoonBit decode plan. The
decoder returns a source-mapped value tree, so a native CLI, JSON exporter, or
WASM inspector can all point back to the exact bytes for every field.

## MVP capabilities

- `u8`, `u16`, and `u32` primitives
- Big- and little-endian decoding
- Fixed byte/ascii fields: `bytes[8]`, `ascii[4]`
- Dependent byte/ascii fields: `bytes[length]`
- Exact truncation diagnostics with field path, offset, expected, and remaining bytes
- Field offset and byte length in every decoded node

The V1 grammar deliberately excludes conditionals, unions, bitfields,
serialization, and streaming. Those features belong after the small core is
stable.

## Quick start

```bash
moon test
moon run cmd/main
```

The CLI runs the sensor-packet demo and prints an inspector tree:

```text
SensorPacket
|- magic: 43605  [offset 0x0, length 2]
|- version: 1  [offset 0x2, length 1]
|- payload_len: 3  [offset 0x3, length 2]
|- payload: 0x102030  [offset 0x5, length 3]
```

## Schema example

```mbs
format SensorPacket endian little {
	magic       : u16
	version     : u8
	payload_len : u16
	payload     : bytes[payload_len]
}
```

`schemas/png.mbs` and `schemas/sensor.mbs` are ready-to-use format examples.
The core has no file or browser dependency, preserving the path to Native,
WASM, and JavaScript front ends.

## Status

This repository is the V1 decoder-core milestone. Nested structures, repeated
records, `expect`, JSON rendering, native file arguments, and the WASM
inspector are planned next. The design is inspired by declarative binary
format systems such as Kaitai Struct, with a deliberately smaller,
MoonBit-native schema language.