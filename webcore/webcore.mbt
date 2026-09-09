///|
/// The Browser Inspector's entry point into the shared MoonBit core. This
/// package's only job is to be compiled with `moon build --target js` and
/// export `decode_to_json` (see `moon.pkg`), so the exact same
/// schema-parser and decoder that power the Native CLI also power the
/// browser: no logic is duplicated in JavaScript.
///
/// `Bytes` and `String` map directly to `Uint8Array` and `string` on the JS
/// side, so the exported signature is callable from plain JavaScript with
/// no marshalling glue.

///|
fn main {

}

///|
/// Parses `schema_source` and decodes `bytes` against its root format,
/// returning a single JSON string so the JS caller never has to understand
/// MoonBit's `Result`/enum representation: `{"ok":true,"root":...}` on
/// success, `{"ok":false,"stage":"schema"|"decode",...}` on failure.
pub fn decode_to_json(schema_source : String, bytes : Bytes) -> String {
  match @spec.parse_document(schema_source) {
    Err(message) =>
      "{\"ok\":false,\"stage\":\"schema\",\"message\":\"\{@spec.json_escape(message)}\"}"
    Ok(document) =>
      match @spec.decode(document, bytes) {
        Ok(root) => "{\"ok\":true,\"root\":\{@spec.render_json(root)}}"
        Err(error) =>
          "{\"ok\":false,\"stage\":\"decode\",\"path\":\"\{@spec.json_escape(error.path)}\",\"offset\":\{error.offset},\"expected\":\{error.expected},\"remaining\":\{error.remaining},\"reason\":\"\{@spec.json_escape(error.reason)}\"}"
      }
  }
}
