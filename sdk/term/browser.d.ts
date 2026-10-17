// `@libfx/term` in browsers: libfx's createFxTerminal(), with `wasm` set to
// this package's fx-term.wasm unless the caller passes one.
export { createFxTerminal, encodeXtermKeyEvent, xtermAdapter } from "libfx/browser";
export type {
  FxBrowserTerminalOptions,
  FxTerminal,
  FxTerminalAdapter,
  FxTerminalEvent,
  FxTerminalOptions,
} from "libfx/browser";
