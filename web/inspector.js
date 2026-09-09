import { decode_to_json } from "./webcore.js";

// Demo payloads. Small enough to embed; identical to fixtures/*.
const demos = {
  sensor: {
    bytes: new Uint8Array([0x55, 0xaa, 0x01, 0x03, 0x00, 0x10, 0x20, 0x30]),
    schema: `format SensorPacket endian little {
  magic       : u16
  version     : u8
  payload_len : u16
  payload     : bytes[payload_len]
}`,
    label: "demo.sensor",
  },
  png: {
    bytes: new Uint8Array([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,0xde,0x00,0x00,0x00,0x0c,0x49,0x44,0x41,0x54,0x78,0x9c,0x63,0xe0,0x12,0x91,0x03,0x00,0x00,0x68,0x00,0x3d,0x54,0x08,0xa3,0xf7,0x00,0x00,0x00,0x00,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82]),
    schema: `format PngChunk endian big {
  length : u32
  kind   : ascii[4]
  data   : bytes[length]
  crc    : u32
}

format PNG endian big {
  signature : bytes[8] expect hex("89504E470D0A1A0A")
  chunks    : PngChunk[*] until eof
}`,
    label: "sample.png",
  },
  "corrupt-png": {
    bytes: new Uint8Array([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0x00,0x00,0x00,0x0d,0x49,0x48,0x44,0x52,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,0xde,0x00,0x00,0x27,0x1c,0x49,0x44,0x41,0x54,0x78,0x9c,0x63,0xe0,0x12,0x91,0x03,0x00,0x00,0x68,0x00,0x3d,0x54,0x08,0xa3,0xf7,0x00,0x00,0x00,0x00,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82]),
    schema: null, // reuses the PNG schema already in the textarea
    label: "corrupt.png",
  },
  wav: {
    bytes: new Uint8Array([0x52,0x49,0x46,0x46,0x28,0x00,0x00,0x00,0x57,0x41,0x56,0x45,0x66,0x6d,0x74,0x20,0x10,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x44,0xac,0x00,0x00,0x44,0xac,0x00,0x00,0x01,0x00,0x08,0x00,0x64,0x61,0x74,0x61,0x04,0x00,0x00,0x00,0x80,0x80,0x80,0x80]),
    schema: `format WavChunk endian little {
  id   : ascii[4]
  size : u32
  data : bytes[size]
}

format WAV endian little {
  riff      : ascii[4] expect hex("52494646")
  file_size : u32
  wave      : ascii[4] expect hex("57415645")
  chunks    : WavChunk[*] until eof
}`,
    label: "sample.wav",
  },
};

const maxHexBytes = 8192;
const maxInputBytes = 64 * 1024 * 1024;

const state = { bytes: demos.sensor.bytes, entries: [], selected: null };

const $ = (selector) => document.querySelector(selector);

function escapeHtml(value) {
  return String(value).replace(
    /[&<>'"]/g,
    (character) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[
        character
      ],
  );
}

// A decoded node's `value` is one of: number (int/uint), string (text or
// "0x..." bytes), Array (repeated struct/scalar), or a plain object mapping
// field name -> child node (a decoded struct). This mirrors MoonBit's
// `Value` enum (see decoder.mbt) as plain JSON.
function nodeKind(value) {
  if (typeof value === "number") return "number";
  if (typeof value === "string") return "text";
  if (Array.isArray(value)) return "array";
  return "object";
}

function preview(node, kind) {
  if (kind === "number") return String(node.value);
  if (kind === "text") return node.value;
  if (kind === "array") return `[${node.value.length}]`;
  return `{${Object.keys(node.value).length}}`;
}

function typeLabel(kind, node) {
  if (kind === "number") return "integer";
  if (kind === "text") return /^0x[0-9A-Fa-f]*$/.test(node.value) ? "bytes" : "text";
  if (kind === "array") return `array[${node.value.length}]`;
  return `struct{${Object.keys(node.value).length}}`;
}

function childrenOf(node, kind) {
  if (kind === "array") return node.value;
  if (kind === "object") return Object.values(node.value);
  return [];
}

// Flattens the node tree into a pre-order list of {node, path, depth} so the
// tree panel and the hex<->field linking can both work off plain arrays.
function flatten(node, path, depth, out) {
  const kind = nodeKind(node.value);
  out.push({ node, path, depth, kind });
  for (const child of childrenOf(node, kind)) {
    const childPath = child.name.startsWith("[")
      ? `${path}${child.name}`
      : `${path}.${child.name}`;
    flatten(child, childPath, depth + 1, out);
  }
}

function renderTree(rootLabel, entries) {
  const tree = $("#tree");
  tree.innerHTML = `<div class="tree-format">${escapeHtml(rootLabel)}</div>`;
  entries.forEach((entry, index) => {
    const button = document.createElement("button");
    button.className = `field ${state.selected === index ? "active" : ""}`;
    button.style.paddingLeft = `${8 + entry.depth * 14}px`;
    button.innerHTML = `<span class="dot"></span><span>${escapeHtml(entry.node.name)}</span><span class="value">${escapeHtml(preview(entry.node, entry.kind))}</span>`;
    button.onclick = () => select(index);
    tree.append(button);
  });
}

function renderHex() {
  const bytes = state.bytes;
  const shown = Math.min(bytes.length, maxHexBytes);
  $("#byte-count").textContent =
    bytes.length > maxHexBytes
      ? `${bytes.length} bytes; showing first ${maxHexBytes}`
      : `${bytes.length} bytes`;
  const active = state.selected === null ? null : state.entries[state.selected].node;
  const hex = $("#hex");
  hex.innerHTML = "";
  for (let start = 0; start < shown; start += 16) {
    const row = document.createElement("div");
    row.className = "hex-row";
    const cells = [];
    for (let i = start; i < Math.min(start + 16, shown); i++) {
      const hit = active !== null && i >= active.offset && i < active.offset + active.length;
      cells.push(
        `<span class="byte ${hit ? "active" : ""}" data-index="${i}">${bytes[i].toString(16).padStart(2, "0").toUpperCase()}</span>`,
      );
    }
    const asciiText = [...bytes.slice(start, start + 16)]
      .map((byte) => (byte >= 32 && byte < 127 ? String.fromCharCode(byte) : "."))
      .join("");
    row.innerHTML = `<span class="offset">${start.toString(16).padStart(8, "0").toUpperCase()}</span><span>${cells.join("")}</span><span class="ascii">${escapeHtml(asciiText)}</span>`;
    hex.append(row);
  }
  hex.querySelectorAll(".byte").forEach((byte) => {
    byte.onclick = () => {
      const index = Number(byte.dataset.index);
      // Pick the most specific (smallest) node whose range covers this byte.
      let best = -1;
      for (let i = 0; i < state.entries.length; i++) {
        const node = state.entries[i].node;
        if (index >= node.offset && index < node.offset + node.length) {
          if (best === -1 || node.length < state.entries[best].node.length) {
            best = i;
          }
        }
      }
      if (best >= 0) select(best);
    };
  });
}

function renderDetail() {
  const root = $("#detail");
  if (state.selected === null) {
    root.className = "detail empty";
    root.textContent = "Select a field or byte range.";
    return;
  }
  const entry = state.entries[state.selected];
  root.className = "detail";
  root.innerHTML = `<dl>
    <dt>Path</dt><dd>${escapeHtml(entry.path)}</dd>
    <dt>Offset</dt><dd>0x${entry.node.offset.toString(16).toUpperCase()} (${entry.node.offset})</dd>
    <dt>Size</dt><dd>${entry.node.length} byte${entry.node.length === 1 ? "" : "s"}</dd>
    <dt>Type</dt><dd>${escapeHtml(typeLabel(entry.kind, entry.node))}</dd>
    <dt>Value</dt><dd>${escapeHtml(preview(entry.node, entry.kind))}</dd>
  </dl>`;
}

function select(index) {
  state.selected = index;
  renderTree($("#format-name").textContent, state.entries);
  renderHex();
  renderDetail();
}

function showStructuralError(result) {
  $("#schema-state").textContent = "valid";
  $("#schema-state").style.color = "";
  $("#format-name").textContent = "";
  $("#tree").innerHTML = `<div class="tree-format" style="color:#b4402e">STRUCTURAL ERROR</div>`;
  const detail = $("#detail");
  detail.className = "detail";
  detail.innerHTML = `<dl>
    <dt>Path</dt><dd>${escapeHtml(result.path)}</dd>
    <dt>Offset</dt><dd>0x${result.offset.toString(16).toUpperCase()} (${result.offset})</dd>
    <dt>Expected</dt><dd>${result.expected} bytes</dd>
    <dt>Remaining</dt><dd>${result.remaining} bytes</dd>
    <dt>Reason</dt><dd>${escapeHtml(result.reason)}</dd>
  </dl>`;
  state.entries = [];
  state.selected = null;
  renderHex();
}

function run() {
  const source = $("#schema").value;
  const result = JSON.parse(decode_to_json(source, state.bytes));
  if (!result.ok && result.stage === "schema") {
    $("#schema-state").textContent = "error";
    $("#schema-state").style.color = "#b4402e";
    $("#format-name").textContent = "";
    $("#tree").innerHTML = "";
    const detail = $("#detail");
    detail.className = "detail";
    detail.textContent = result.message;
    state.entries = [];
    state.selected = null;
    renderHex();
    return;
  }
  if (!result.ok) {
    showStructuralError(result);
    return;
  }
  const entries = [];
  flatten(result.root, result.root.name, 0, entries);
  state.entries = entries;
  // entries[0] is the root itself (its range spans the whole input), so
  // default to the first real field instead of highlighting every byte.
  state.selected = entries.length > 1 ? 1 : entries.length ? 0 : null;
  $("#format-name").textContent = result.root.name;
  $("#schema-state").textContent = "valid";
  $("#schema-state").style.color = "";
  renderTree(result.root.name, entries);
  renderHex();
  renderDetail();
}

function loadDemo(name) {
  const demo = demos[name];
  if (demo.schema) $("#schema").value = demo.schema;
  state.bytes = demo.bytes;
  $("#file-name").textContent = demo.label;
  run();
}

function detectSchema(bytes) {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) {
    return demos.png.schema;
  }
  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x41 && bytes[10] === 0x56 && bytes[11] === 0x45
  ) {
    return demos.wav.schema;
  }
  return null;
}

$("#decode").onclick = run;
$("#sensor-demo").onclick = () => loadDemo("sensor");
$("#png-demo").onclick = () => loadDemo("png");
$("#corrupt-demo").onclick = () => loadDemo("corrupt-png");
$("#wav-demo").onclick = () => loadDemo("wav");
$("#open-file").onclick = () => $("#file-input").click();
$("#file-input").onchange = (event) => {
  const file = event.target.files[0];
  if (!file) return;
  if (file.size > maxInputBytes) {
    $("#file-name").textContent = "File exceeds 64 MiB limit";
    $("#detail").className = "detail";
    $("#detail").textContent = "Choose a file smaller than 64 MiB for browser inspection.";
    event.target.value = "";
    return;
  }
  $("#file-name").textContent = `Loading ${file.name}...`;
  const reader = new FileReader();
  reader.onload = () => {
    state.bytes = new Uint8Array(reader.result);
    const detectedSchema = detectSchema(state.bytes);
    if (detectedSchema !== null) $("#schema").value = detectedSchema;
    $("#file-name").textContent = file.name;
    run();
  };
  reader.onerror = () => {
    $("#detail").className = "detail";
    $("#detail").textContent = "The selected file could not be read by this browser.";
  };
  reader.readAsArrayBuffer(file);
  event.target.value = "";
};

run();
