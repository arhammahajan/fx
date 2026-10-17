import { createDurableAgentFactory, memory } from "./durable.js";
import { fxHarness } from "./fx-harness.js";
import {
  createFxEngine as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  createMemoryPersistence,
  FxFencedError,
  FxJournalVersionError,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./fx-sdk.js";

export { createMemoryPersistence, encodeXtermKeyEvent, FxFencedError, FxJournalVersionError, fxSdkApiVersion, listModels, memory, supportsJspi, xtermAdapter };
export const libfxApiVersion = 3;

const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url).href;

/** One fx session on WebAssembly, with no durability of its own. */
export function createFxEngine(options = {}) {
  return createWasmAgent({ ...options, wasm: options.wasm ?? defaultCoreWasm });
}

/** An agent whose sessions live in this page unless `durability` says otherwise. */
export const createFxAgent = createDurableAgentFactory({
  name: "createFxAgent",
  label: "fx agent",
  defaultDurability: async () => memory(),
  harness: fxHarness({ createEngine: createFxEngine }),
});

// The terminal's WebAssembly ships in @libfx/term (PKG-3), whose
// createFxTerminal() passes it as `wasm`.
export async function createFxTerminal(options = {}) {
  if (options.wasm === undefined) {
    throw new TypeError('createFxTerminal() needs the fx terminal\'s WebAssembly, which ships in @libfx/term: import createFxTerminal from "@libfx/term", or pass wasm');
  }
  return createWasmTerminal(options);
}
