#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
status=0

for stream in "$root"/tests/v27/streams/valid-*.ndjson; do
  bun "$root/tests/v27/check.ts" "$stream" || status=1
done

for stream in "$root"/tests/v27/streams/broken-*.ndjson; do
  expected=$(basename "$stream" .ndjson)
  expected=${expected#broken-}
  output=$(bun "$root/tests/v27/check.ts" "$stream" 2>&1) && passed=1 || passed=0
  if [ "$passed" -eq 1 ]; then
    echo "expected failure: $stream" >&2
    status=1
  elif ! printf '%s\n' "$output" | grep -q ": $expected:"; then
    echo "expected rule $expected: $stream" >&2
    printf '%s\n' "$output" >&2
    status=1
  fi
done

exit "$status"
