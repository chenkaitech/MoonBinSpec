# Contributing to MoonBinSpec

## Prerequisites

Install MoonBit from <https://www.moonbitlang.com/download/>. The browser
Inspector uses only a static HTTP server and a current Node.js runtime for its
syntax check.

## Development checks

Run this quality gate before opening a pull request:

```bash
moon fmt
moon info
moon test
moon test --target js
moon test --target wasm-gc
moon build --target native cmd/main
web/build-core.sh
git diff --exit-code -- web/webcore.js
node --check web/inspector.js
```

`web/webcore.js` is a generated release artifact used by the static Inspector.
When changing the core API or the `webcore` package, run `web/build-core.sh`
and include the updated artifact in the same change.

## Scope and package boundaries

Keep the parser and AST in `MoonBinSpec.mbt`, decoding in `decoder.mbt`, and
rendering in `render.mbt`. The core library must remain free of file and
browser APIs so it can compile to Native, JS, and Wasm. Native I/O belongs in
`cmd/main`; browser export glue belongs in `webcore`.

Add a focused `_test.mbt` case for each parser or decoder behavior change. For
format-level regressions, add or update a fixture under `fixtures/` and cover
it through a schema under `schemas/`.
