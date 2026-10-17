import { createFxTerminal as createTerminal } from "libfx/browser";

export { encodeXtermKeyEvent, xtermAdapter } from "libfx/browser";

// The terminal's WebAssembly, an asset bundlers copy into their output.
const defaultWasm = new URL("./fx-term.wasm", import.meta.url).href;

/** libfx's createFxTerminal() with this package's fx-term.wasm. */
export function createFxTerminal(options = {}) {
  return createTerminal({ ...options, wasm: options?.wasm ?? defaultWasm });
}
