// `@libfx/term` on Node.js: libfx's createFxTerminal(), with `wasm` set to
// this package's fx-term.wasm unless the caller passes one.
export { createFxTerminal, encodeXtermKeyEvent, xtermAdapter } from "libfx/node";
export type {
  FxNodeTerminalOptions,
  FxTerminal,
  FxTerminalAdapter,
  FxTerminalEvent,
  FxTerminalOptions,
} from "libfx/node";
