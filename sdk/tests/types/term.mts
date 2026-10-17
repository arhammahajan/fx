// @libfx/term (PKG-3): libfx's createFxTerminal() with the terminal's
// WebAssembly, so `wasm` stays optional, and the xterm.js helpers.
import { createFxTerminal, encodeXtermKeyEvent, xtermAdapter, type FxTerminal, type FxTerminalAdapter, type FxTerminalEvent } from "@libfx/term";

declare const adapter: FxTerminalAdapter;

const started: Promise<FxTerminal> = createFxTerminal({
  terminal: adapter,
  env: { AI_GATEWAY_API_KEY: "key" },
  onEvent(event: FxTerminalEvent) {
    void event.type;
  },
});
const withWasm: Promise<FxTerminal> = createFxTerminal({ terminal: adapter, wasm: "/fx-term.wasm" });
const bytes: string | null = encodeXtermKeyEvent({ type: "keydown", key: "Enter", altKey: false, ctrlKey: false, shiftKey: true, metaKey: false });
void started;
void withWasm;
void bytes;
void xtermAdapter;

// @ts-expect-error a terminal adapter is required
void createFxTerminal({});
