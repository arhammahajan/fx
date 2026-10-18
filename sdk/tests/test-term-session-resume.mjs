#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxTerminal, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-term.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-term-session-resume.mjs");
  process.exit(2);
}

const wasm = await readFile(wasmPath);
const encoded = new TextEncoder();
let fetchCalls = 0;
const mockFetch = async () => {
  fetchCalls += 1;
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","id":"answer","delta":"ZXQJ"}\n\n'));
      controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n'));
      controller.enqueue(encoded.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

const records = new Map();
let nextRevision = 1;
let commits = 0;
let commitCalls = 0;
const sessionStore = {
  load(id) {
    const record = records.get(id);
    return record ? { bytes: record.bytes.slice(), revision: record.revision } : null;
  },
  commit(id, bytes, expectedRevision) {
    commitCalls += 1;
    const current = records.get(id);
    if (current?.revision !== expectedRevision) {
      const error = new Error("session revision conflict");
      error.code = "FX_SESSION_REVISION_CONFLICT";
      throw error;
    }
    const revision = String(nextRevision++);
    records.set(id, { bytes: bytes.slice(), revision, updatedAtMs: Date.now() });
    commits += 1;
    return { revision };
  },
  list() {
    return [...records.entries()].map(([id, record]) => ({
      id,
      updatedAtMs: record.updatedAtMs,
    }));
  },
  remove(id) {
    records.delete(id);
  },
};

function createTerminalCapture() {
  const decoder = new TextDecoder();
  let text = "";
  return {
    terminal: {
      cols: 80,
      rows: 24,
      write(value) {
        const bytes = value instanceof Uint8Array ? value : encoded.encode(value);
        text += decoder.decode(bytes, { stream: true });
      },
      async drain() {},
      onData() { return () => {}; },
      onResize() { return () => {}; },
    },
    text() { return text; },
  };
}

async function waitFor(predicate, label, diagnostics = () => "") {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() >= deadline) {
      throw new Error(`timed out waiting for ${label}: ${diagnostics()}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function start(args = []) {
  const capture = createTerminalCapture();
  const events = [];
  const runtime = await createFxTerminal({
  backend: "wasm",
    wasm,
    args,
    terminal: capture.terminal,
    env: { AI_GATEWAY_API_KEY: "term-session-test-key", FX_THEME: "dark" },
    fetch: mockFetch,
    sessionStore,
    onEvent(event) { events.push(event); },
  });
  await waitFor(
    () => capture.text().includes(args.length ? "session resumed" : "Run /help for commands"),
    "fx-term startup",
    () => `output=${JSON.stringify(capture.text().slice(-1000))}`,
  );
  return { capture, runtime, events };
}

async function exit(runtime, label) {
  runtime.write("/exit\r");
  const exitCode = await Promise.race([
    runtime.exited,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out waiting for ${label} exit`)), 5000)),
  ]);
  if (exitCode !== 0) throw new Error(`${label} exited with code ${exitCode}`);
}

const first = await start();
first.runtime.write("remember this browser turn\r");
await waitFor(
  () => fetchCalls === 1,
  "gateway response",
  () => `commits=${commits}, fetches=${fetchCalls}, output=${JSON.stringify(first.capture.text().slice(-1000))}`,
);
await waitFor(
  () => commits === 1,
  "completed-turn session commit",
  () => `commits=${commits}, fetches=${fetchCalls}, output=${JSON.stringify(first.capture.text().slice(-1000))}`,
);
await exit(first.runtime, "first terminal");

const second = await start(["--resume", "last"]);
const restoredBeforeInput = second.capture.text();
if (!restoredBeforeInput.includes("remember this browser turn")) {
  throw new Error("second terminal did not replay the restored user prompt before input");
}
if (!restoredBeforeInput.includes("ZXQJ")) {
  throw new Error("second terminal did not replay the restored assistant reply before input");
}
if (fetchCalls !== 1) throw new Error("restore triggered an unexpected gateway request");
await exit(second.runtime, "second terminal");

// Another writer saves the conversation; this terminal's next commit carries
// a stale revision. The store's FX_SESSION_REVISION_CONFLICT reaches the app
// and the user, the record stays as the store has it, and fx stops saving.
const third = await start(["--resume", "last"]);
const [sessionId] = records.keys();
const otherWriter = { ...records.get(sessionId), revision: "other-writer" };
records.set(sessionId, otherWriter);
const callsBefore = commitCalls;
third.runtime.write("a turn after another writer saved\r");
await waitFor(
  () => third.events.some((event) => event.type === "session.persist_error"),
  "the conflict diagnostic",
  () => `commitCalls=${commitCalls}, events=${JSON.stringify(third.events.map((event) => event.type))}`,
);
const conflict = third.events.find((event) => event.type === "session.persist_error");
if (conflict.sessionId !== sessionId || conflict.error?.code !== "FX_SESSION_REVISION_CONFLICT") {
  throw new Error(`session.persist_error should name the session and carry the store's error: ${JSON.stringify({ sessionId: conflict.sessionId, code: conflict.error?.code })}`);
}
await waitFor(
  () => third.capture.text().includes("this conversation was saved elsewhere"),
  "the conflict notice",
  () => `output=${JSON.stringify(third.capture.text().slice(-1500))}`,
);
const callsAfterConflict = commitCalls;
if (callsAfterConflict !== callsBefore + 1) throw new Error(`expected one refused commit, got ${callsAfterConflict - callsBefore}`);
const fetchesBefore = fetchCalls;
third.runtime.write("one more turn\r");
await waitFor(() => fetchCalls > fetchesBefore, "the next reply");
await new Promise((resolve) => setTimeout(resolve, 200));
if (commitCalls !== callsAfterConflict) throw new Error(`fx kept committing after the conflict (${commitCalls - callsAfterConflict} more)`);
if (records.get(sessionId) !== otherWriter) throw new Error("a commit replaced the other writer's record");
await exit(third.runtime, "conflicting terminal");

console.log(`term session resume passed: commits=${commits}, records=${records.size}, restored_prompt=true, restored_reply=true, conflict_reported=true`);
