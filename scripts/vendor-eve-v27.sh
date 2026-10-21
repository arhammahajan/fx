#!/bin/sh
set -eu

pin=badc42fbfb2d5e0df6058807a63246171432f999
eve_checkout=${1:-}

if [ -z "$eve_checkout" ]; then
  echo "usage: scripts/vendor-eve-v27.sh <eve-checkout>" >&2
  exit 2
fi

actual=$(git -C "$eve_checkout" rev-parse HEAD)
if [ "$actual" != "$pin" ]; then
  echo "eve checkout is $actual; expected $pin" >&2
  exit 1
fi

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
eve_package="$eve_checkout/packages/eve"
generated="$eve_package/.generated/compiled/zod"
entry="$eve_package/.fx-v27-vendor-entry.ts"

cleanup() {
  rm -f "$entry"
  rm -rf "$eve_package/.generated"
  if [ -n "${vendor_tools:-}" ]; then rm -rf "$vendor_tools"; fi
}
trap cleanup EXIT INT TERM

mkdir -p "$generated" "$repo_root/tests/v27"
cat > "$generated/index.ts" <<'EOF'
export * from "zod";
EOF

cat > "$entry" <<'EOF'
import { FACT_CATALOG } from "./src/protocol/session-events/catalog.ts";
import { createStreamChecker } from "./src/protocol/session-events/checker.ts";
import type { StoredLine } from "./src/protocol/session-events/envelope.ts";
import { schemaViolation } from "./src/protocol/session-events/schemas.ts";
import { emptySessionView, foldLine } from "./src/protocol/session-projection/fold.ts";

export const catalog = FACT_CATALOG;

export function check(lines: readonly StoredLine[]) {
  const checker = createStreamChecker({ validate: schemaViolation });
  return lines.flatMap((line, position) => checker.check(line, position));
}

export function fold(lines: readonly StoredLine[]) {
  const view = emptySessionView();
  lines.forEach((line, position) => foldLine(view, line, position));
  return view;
}
EOF

header="// Vendored from vercel/eve $pin. Regenerate with scripts/vendor-eve-v27.sh."
bundle_tmp="$repo_root/tests/v27/eve-v27.bundle.mjs"
vendor_tools=$(mktemp -d)
npm install --silent --no-package-lock --prefix "$vendor_tools" esbuild@0.25.11 zod@4.5.4

(
  cd "$eve_checkout"
  "$vendor_tools/node_modules/.bin/esbuild" \
    "$entry" \
    --bundle \
    --conditions=eve-source \
    --format=esm \
    --platform=node \
    --alias:zod="$vendor_tools/node_modules/zod" \
    --outfile="$bundle_tmp"
)

{
  printf '%s\n' "$header"
  cat "$bundle_tmp"
} > "$repo_root/tests/v27/eve-v27.mjs"
rm "$bundle_tmp"

node --input-type=module - "$repo_root/tests/v27/eve-v27.mjs" \
  > "$repo_root/tests/v27/catalog.json" <<'EOF'
const modulePath = process.argv[2];
const { catalog } = await import(modulePath);
process.stdout.write(`${JSON.stringify(catalog, null, 2)}\n`);
EOF
