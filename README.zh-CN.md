# MoonBinSpec

[English](README.mbt.md) | **中文**

**面向 MoonBit 的声明式二进制格式解析、验证与可视化工具。**

解析二进制文件和网络协议时，开发者通常要为每一种格式重复编写位移、长度、
大小端等底层处理代码。MoonBinSpec 让你只需用一份精简的 `.mbs` schema
描述一次二进制格式，就能同时获得解析器、校验器、JSON 导出，以及能精确
定位到字节的可视化 Inspector —— 这一切都基于同一套纯 MoonBit 解码核心，
Native CLI 与浏览器 Inspector 共用同一份实现。

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

MoonBinSpec 的设计参考了 [Kaitai Struct](https://kaitai.io/) 等成熟的
声明式二进制格式方案，但它是一个更紧凑的 MoonBit 原生工具，schema
语言也刻意做得更小。

## Schema 语言（V1）

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

一个 schema 文件可以声明一个或多个 `format` 代码块；**最后一个**
即为解码时使用的根格式，前面声明的格式则作为嵌套结构被引用。目前
支持的字段类型：

| 能力 | 语法 |
| --- | --- |
| 无符号 / 有符号整数 | `u8 u16 u32 u64 i8 i16 i32 i64` |
| 大小端 | `format X endian big { ... }` / `endian little` |
| 定长字节 / 文本 | `bytes[8]`、`ascii[4]` |
| 依赖长度的字节 / 文本 | `bytes[length]`、`ascii[name]`（引用前面某个无符号字段） |
| 嵌套结构 | `header : Header`（引用同一文档中的另一个 `format`） |
| 定长数组 | `items : Sample[4]`、`items : Sample[count]` |
| 读到文件末尾的数组 | `chunks : PngChunk[*] until eof` |
| 常量断言 | `magic : bytes[4] expect hex("89504E47")`（仅支持定长的 `bytes`/`ascii`） |
| 注释 | `// ...` 到行尾 |

`expect` 和 `until eof` 是写在字段同一行末尾的修饰符（而不是另起一
个缩进行）—— 这样解析器可以保持单遍、按行扫描的实现方式，不需要跨
行向前看。

V1 有意不支持：通用表达式语言、位域（bitfield）、条件字段、联合体
（union）、枚举代码生成、序列化器，以及流式解析 —— 这些特性都会带来
真实的复杂度，而当前的 schema 语言还用不上它们。完全兼容 Kaitai
Struct 也不是 MoonBinSpec 的目标。

## 值树（Value Tree）

解码器不会直接产出 JSON，而是先构建一棵带有源码字节映射信息的树：

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

无论是终端树状输出、JSON，还是浏览器 Inspector，所有渲染器都遍历同
一棵 `Node` 树，因此每个字段都始终携带着它在原始字节流中的准确位置。

## CLI

```bash
moon run cmd/main --target native -- check schemas/png.mbs
moon run cmd/main --target native -- inspect fixtures/sample.png -s schemas/png.mbs
moon run cmd/main --target native -- decode  fixtures/sample.png -s schemas/png.mbs --json
moon run cmd/main --target native -- validate fixtures/sample.png -s schemas/png.mbs
```

`inspect` 会打印字段树：

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

给它一个故意损坏的文件（`fixtures/corrupt.png`，其中 `IDAT` chunk
声明的长度远大于文件剩余的字节数），就能看到 MoonBinSpec 的另一半
价值 —— 它不只是"看"字节，还会校验结构：

```
STRUCTURAL ERROR

PNG.chunks[1].data

offset:     0x29
expected:   10012 bytes
remaining:  28 bytes
reason:     field length exceeds remaining input
```

`schemas/` 目录下有可以直接使用的格式定义（`png.mbs`、`wav.mbs`、
`sensor.mbs`）；`fixtures/` 目录下有对应的真实（以及故意损坏的）
示例文件。

CLI 只能在 Native 后端运行（因为它需要通过 `moonbitlang/x/fs` 做真
实的文件 I/O）；解码核心本身则完全没有文件或平台相关的依赖。

## 浏览器 Inspector

浏览器 Inspector 运行的是**完全相同**的 MoonBit 解码核心 —— 编译成
JS，而不是用 JavaScript 重新实现一遍。`webcore/webcore.mbt` 是一个
很薄的包，它引入核心库，并通过 `moon.pkg` 的 `link.js.exports`
导出一个函数 `decode_to_json(schema_source, bytes) -> String`；
MoonBit 的 JS 后端会把 `Bytes` 直接映射为 `Uint8Array`、`String`
映射为 `string`，因此浏览器调用它时不需要任何额外的类型转换代码。

```bash
web/build-core.sh          # 执行 moon build --target js webcore --release，
                            # 然后把产物拷贝到 web/webcore.js
cd web && python3 -m http.server 4173
```

打开 <http://localhost:4173>。加载一个文件（或者点击 PNG / 损坏的
PNG / WAV / sensor packet 几个演示按钮），即可看到字段树、十六进制
视图和字段详情面板；点击某个字段会在十六进制视图中高亮对应的字节
区间，反之点击字节区间也能定位到对应字段。解码错误会渲染成与 CLI
相同的结构化错误报告。

## 测试

```bash
moon test                 # native
moon test --target js
moon test --target wasm-gc
```

测试覆盖了 schema 解析（包括各种非法 schema）、基础类型的大小端与
符号扩展、依赖长度的字段、嵌套结构、定长数组与读到文件末尾的数组、
`expect` 常量校验、JSON 渲染，以及使用 `fixtures/` 下的真实文件
（包括损坏的文件）配合 `schemas/` 下真实 schema 的黄金样例测试 ——
和 CLI、浏览器 Inspector 使用的是同一套流程。

## 项目结构

```
MoonBinSpec.mbt      schema 的 AST 与解析器（.mbs 语法）
decoder.mbt          解码引擎：Document + 字节 -> 值树
render.mbt           终端树状 / JSON 渲染器
cmd/main/            Native CLI（通过 moonbitlang/x/fs 做文件 I/O）
webcore/             面向浏览器的 JS 导出解码入口
web/                 静态的浏览器 Inspector（HTML/CSS/JS）
schemas/             示例 .mbs 格式定义（png、wav、sensor）
fixtures/            真实文件以及故意损坏的样例二进制文件
```

核心库（`MoonBinSpec.mbt`、`decoder.mbt`、`render.mbt`）放在同一个
包里，而不是拆分成独立的 `schema/`、`decoder/`、`model/`、
`render/` 子包 —— 在目前这个规模下，把它们拆到同一模块下的多个包
只会增加 import 的接线工作，却带不来实际收益；现在按文件拆分已经
把语法、解码、渲染这三部分关注点分开了，方便阅读代码的人理解。

## 现状

已实现：完整的 V1 schema 语法（8～64 位有符号/无符号整数、两种大
小端、定长与依赖长度的 bytes/ascii、嵌套结构、定长数组与读到文件
末尾的数组、`expect` 常量校验）、产出带字节映射信息值树的解码引擎、
终端与 JSON 渲染器、具备真实文件 I/O 与四个命令
（`check`/`inspect`/`decode`/`validate`）的 Native CLI、运行真实
编译到 JS 的核心的浏览器 Inspector，以及配有真实（及损坏）样例文件、
并被测试套件覆盖的 PNG/WAV/sensor packet schema。

已知缺口：CLI 在 `validate`/`decode` 失败时不会返回非零的进程退出
码（会打印结构化错误信息，但进程仍以状态码 0 退出 —— 目前
`moonbitlang/core` 并未在 Native 运行时中暴露设置进程退出码的
API）；`.mbs` 语法目前还不支持位域、条件字段、联合体，也没有
MoonBit 代码生成（这些都是刻意推迟到未来版本的功能）。
