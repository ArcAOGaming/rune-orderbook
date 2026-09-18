#!/usr/bin/env bash
# Run the sharded venue suite (vaults + pairs as a network) on a free public
# HyperBEAM Lua device. No wallet, signing, process spawn, or payment.
set -euo pipefail

NODE="${1:-https://alpha.neo.zephyrdev.xyz}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACTS="$ROOT/contracts"

BUNDLE="$(mktemp)"
trap 'rm -f "$BUNDLE"' EXIT
{
  cat "$CONTRACTS/json.lua"
  echo "local C = (function()"; cat "$CONTRACTS/constants.lua"; echo "end)()"
  echo "local jsonx = (function()"; cat "$CONTRACTS/jsonenc.lua"; echo "end)()"
  echo "local encode, jsonObject = jsonx.encode, jsonx.object"
  echo "local OrderBook = (function()"; cat "$CONTRACTS/orderbook.lua"; echo "end)()"
  echo "local Custody = (function()"; cat "$CONTRACTS/custody.lua"; echo "end)()"
  # Each process in its own block: two files of top-level locals in one chunk
  # would pass Lua's 200-locals-per-function limit.
  echo "do"; cat "$CONTRACTS/pair.lua"; echo "end"
  echo "do"; cat "$CONTRACTS/vault.lua"; echo "end"
  cat "$CONTRACTS/sharded_test.lua"
} > "$BUNDLE"

echo "node:   $NODE"
echo "bundle: $(wc -c < "$BUNDLE") bytes"
echo
RESULT="$(curl --fail-with-body -sS -m "${LUA_TEST_TIMEOUT:-600}" -X POST "$NODE/~lua@5.3a/shardedtest" \
  -H 'content-type: application/lua' --data-binary @"$BUNDLE")"
printf '%s\n' "$RESULT"
if ! grep -Eq '(^|[^0-9])0 failed([^0-9]|$)' <<<"$RESULT"; then
  echo "sharded suite did not report zero failures" >&2
  exit 1
fi
