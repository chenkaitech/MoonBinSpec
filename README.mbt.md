# MoonBinSpec

**A declarative binary format parser, validator, and inspector for MoonBit.**

Parsing binary files and network protocols usually means writing the same
offset/length/endian bookkeeping by hand for every format. MoonBinSpec lets
you describe a binary format once, in a small `.mbs` schema, and get a
parser, a validator, a JSON exporter, and a byte-accurate inspector for it —
all from one pure-MoonBit decoder core shared by the Native CLI and a
browser Inspector.

```
              schema (.mbs)
                    │
                    ▼
      Schema Parser → Schema AST
                    │
     bytes ─────────┤
                    ▼
             Decoder Engine
                    │
                    ▼
               Value Tree
          ┌─────────┼─────────┐
          ▼         ▼         ▼
    Terminal CLI   JSON   Browser Inspector
```

MoonBinSpec is inspired by mature declarative binary-format systems such as
[Kaitai Struct](https://kaitai.io/), but is a compact, MoonBit-native
toolkit with a deliberately smaller schema language.

## Schema language (V1)

```mbs
format PngChunk endian big {
  length : u32
  kind   : ascii[4]
  data   : bytes[length]
  crc    : u32
}

format PNG endian big {
  signature : bytes[8] expect hex("89504E470D0A1A0A")
  chunks    : PngChunk[*] until eof
}
```

A schema file declares one or more `format` blocks; the **last** one is the
root format used for decoding, and earlier ones exist to be referenced as
nested structs. Supported field types:

| Feature | Syntax |
| --- | --- |
| Unsigned/signed integers | `u8 u16 u32 u64 i8 i16 i32 i64` |
| Endianness | `format X endian big { ... }` / `endian little` |
| Fixed bytes / text | `bytes[8]`, `ascii[4]` |
| Length-dependent bytes / text | `bytes[length]`, `ascii[name]` (references an earlier unsigned field) |
| Nested struct | `header : Header` (references another `format` in the same document) |
| Fixed-count array | `items : Sample[4]`, `items : Sample[count]` |
| Read-to-end array | `chunks : PngChunk[*] until eof` |
| Constant assertion | `magic : bytes[4] expect hex("89504E47")` (fixed-size `bytes`/`ascii` only) |
| Comments | `// ...` to end of line |

`expect` and `until eof` are single-line suffixes on the field they modify
(not a separate indented line) — this keeps the parser a single-pass,
line-based scanner instead of needing cross-line lookahead.

Deliberately out of scope for V1 (see `prd.md` for the fuller rationale):
a general expression language, bitfields, conditional fields, unions, enum
codegen, a serializer, and streaming. Kaitai-full compatibility is a
non-goal.

## The value tree

The decoder never emits JSON directly. It builds a source-mapped tree first:

```moonbit nocheck
///|
pub enum Value {
  UInt(UInt64)
  Int(Int64)
  Text(String)
  Bytes(Bytes)
  Array(Array[Node])
  Object(Array[Node])
}

///|
pub struct Node {
  name : String
  value : Value
  offset : Int
  length : Int
}
```

Every renderer — the terminal tree, JSON, and the browser Inspector — walks
this same `Node` tree, so every field always carries the exact byte range it
came from.

## CLI

```bash
moon run cmd/main --target native -- check schemas/png.mbs
moon run cmd/main --target native -- inspect fixtures/sample.png -s schemas/png.mbs
moon run cmd/main --target native -- decode  fixtures/sample.png -s schemas/png.mbs --json
moon run cmd/main --target native -- validate fixtures/sample.png -s schemas/png.mbs
```

`inspect` prints a field tree:

```
PNG
|- signature: 0x89504E470D0A1A0A  [offset 0x0, length 8]
|- chunks  [offset 0x8, length 61]
   |- [0]  [offset 0x8, length 25]
      |- length: 13  [offset 0x8, length 4]
      |- kind: "IHDR"  [offset 0xc, length 4]
      |- data: 0x0000000100000001...  [offset 0x10, length 13]
      |- crc: 2423739358  [offset 0x1d, length 4]
   |- [1] ...
   |- [2] ...
```

Feeding it a deliberately corrupted file (`fixtures/corrupt.png`, whose
`IDAT` chunk claims a length far larger than what's left in the file) shows
the other half of the point — MoonBinSpec doesn't just look at bytes, it
validates structure:

```
STRUCTURAL ERROR

PNG.chunks[1].data

offset:     0x29
expected:   10012 bytes
remaining:  28 bytes
reason:     field length exceeds remaining input
```

`schemas/` has ready-to-use formats (`png.mbs`, `wav.mbs`, `sensor.mbs`);
`fixtures/` has real (and corrupted) sample files for each of them.

The CLI is native-only (it needs real file I/O via `moonbitlang/x/fs`); the
decoder core itself has no file or platform dependency at all.

## Browser Inspector

The Inspector runs the *exact same* MoonBit decoder core in the browser —
compiled to JS, not reimplemented in JavaScript. `webcore/webcore.mbt` is a
thin package that imports the core library and exports one function,
`decode_to_json(schema_source, bytes) -> String`, via `moon.pkg`'s
`link.js.exports`; MoonBit's JS backend maps `Bytes` to `Uint8Array` and
`String` to `string` directly, so the browser calls it with no marshalling
code in between.

```bash
web/build-core.sh          # moon build --target js webcore --release, then
                            # copies the output to web/webcore.js
cd web && python3 -m http.server 4173
```

Open <http://localhost:4173>. Load a file (or one of the PNG / corrupted-PNG
/ WAV / sensor-packet demo buttons) to see the field tree, a hex dump, and a
detail panel; clicking a field highlights its byte range in the hex view and
vice versa. Decode errors render the same structural-error report as the CLI.

## Testing

```bash
moon test                 # native
moon test --target js
moon test --target wasm-gc
```

The suite covers schema parsing (including malformed schemas), primitive
endianness and sign extension, dependent-length fields, nested structs,
fixed-count and until-eof arrays, `expect` constant validation, JSON
rendering, and golden-fixture tests that decode the real files under
`fixtures/` (including the corrupted ones) through the real schemas under
`schemas/` — the same pipeline the CLI and the browser Inspector use.

## Project layout

```
MoonBinSpec.mbt      schema AST + parser (the .mbs grammar)
decoder.mbt          decode engine: Document + bytes -> value tree
render.mbt           terminal tree / JSON renderers
cmd/main/            Native CLI (file I/O via moonbitlang/x/fs)
webcore/             JS-exported decode entry point for the browser
web/                 static browser Inspector (HTML/CSS/JS)
schemas/             example .mbs formats (png, wav, sensor)
fixtures/            real + deliberately corrupted sample binaries
```

The core library (`MoonBinSpec.mbt`, `decoder.mbt`, `render.mbt`) lives in
one package rather than the `schema/`, `decoder/`, `model/`, `render/`
sub-packages sketched in early design notes (`prd.md`) — at this size,
splitting into more packages under one module would add import wiring
without a functional benefit; the file split already separates the three
concerns (grammar, decoding, rendering) for anyone reading the code.

## Status

Implemented: the full V1 schema grammar (signed/unsigned 8–64-bit integers,
both endiannesses, fixed and dependent-length bytes/ascii, nested structs,
fixed-count and until-eof arrays, `expect` constants), the decoder engine
producing a source-mapped value tree, terminal and JSON renderers, a Native
CLI with real file I/O and all four PRD commands, a browser Inspector
running the real compiled-to-JS core, and PNG/WAV/sensor-packet schemas
with real (and corrupted) fixtures exercised by the test suite.

Known gaps: the CLI does not set a non-zero process exit code on a failed
`validate`/`decode` (it prints the structural error and exits 0 — MoonBit's
native runtime doesn't expose a process-exit API through `moonbitlang/core`
today); the `.mbs` grammar has no bitfields, conditional fields, unions, or
MoonBit codegen (all deliberately deferred, see `prd.md`).
