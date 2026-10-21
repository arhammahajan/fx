#!/usr/bin/env bun
import { readFile } from "node:fs/promises";

import { check } from "./eve-v27.mjs";
import catalog from "./catalog.json";

interface FxLine {
  kind?: string;
  pos?: number;
  ts?: number;
  facts?: unknown[];
  progress?: unknown;
}

function asEveLine(value: FxLine): unknown | undefined {
  if (value.kind === "snapshot") return undefined;
  if (value.kind === "commit") {
    return {
      at: new Date(value.ts ?? 0).toISOString(),
      facts: value.facts,
    };
  }
  return value;
}

const path = process.argv[2];
if (path === undefined) {
  console.error("usage: bun tests/v27/check.ts <stream.ndjson>");
  process.exit(2);
}

const input = await readFile(path, "utf8");
const knownFacts = new Set(Object.keys(catalog));
const envelopeViolations: string[] = [];
const lines = input
  .split("\n")
  .filter((line) => line.trim().length > 0)
  .map((line, index) => {
    try {
      const parsed = JSON.parse(line);
      if (Array.isArray(parsed.facts)) {
        for (const fact of parsed.facts) {
          if (!knownFacts.has(fact?.type)) envelopeViolations.push(`${path}:${index + 1}: unknown-fact: ${String(fact?.type)}`);
        }
      }
      return asEveLine(parsed);
    } catch (error) {
      console.error(`${path}:${index + 1}: envelope: ${String(error)}`);
      process.exit(1);
    }
  })
  .filter((line) => line !== undefined);

const violations = check(lines);
for (const violation of envelopeViolations) console.error(violation);
for (const violation of violations) {
  const fact = violation.index === undefined ? "" : `:${violation.index + 1}`;
  console.error(
    `${path}:${violation.position + 1}${fact}: ${violation.rule}: ${violation.message}`,
  );
}
if (envelopeViolations.length > 0 || violations.length > 0) process.exit(1);
