import { createFxTerminal as createTerminal } from "libfx/node";

export { encodeXtermKeyEvent, xtermAdapter } from "libfx/node";

// The terminal's WebAssembly, an asset bundlers copy into their output.
const defaultWasm = new URL("./fx-term.wasm", import.meta.url);

/** libfx's createFxTerminal() with this package's fx-term.wasm. */
export function createFxTerminal(options = {}) {
  return createTerminal({ ...options, wasm: options?.wasm ?? defaultWasm });
}
