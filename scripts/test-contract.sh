#!/usr/bin/env bash
# Run the complete venue suite on a free public HyperBEAM Lua device.
# No wallet, signing, process spawn, or payment is involved.
set -euo pipefail

NODE="${1:-https://alpha.neo.zephyrdev.xyz}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACTS="$ROOT/contracts"
AOS="${HYPER_AOS:-$CONTRACTS/json.lua}"

if [ ! -f "$AOS" ]; then
  echo "json.lua not found at $AOS" >&2
  exit 1
fi

BUNDLE="$(mktemp)"
trap 'rm -f "$BUNDLE"' EXIT
{
  cat "$AOS"
  echo "local C = (function()"; cat "$CONTRACTS/constants.lua"; echo "end)()"
  echo "local jsonx = (function()"; cat "$CONTRACTS/jsonenc.lua"; echo "end)()"
  echo "local encode, jsonObject = jsonx.encode, jsonx.object"
  echo "local OrderBook = (function()"; cat "$CONTRACTS/orderbook.lua"; echo "end)()"
  cat "$CONTRACTS/venue.lua"
  cat "$CONTRACTS/venue_test.lua"
} > "$BUNDLE"

echo "node:   $NODE"
echo "bundle: $(wc -c < "$BUNDLE") bytes"
echo
RESULT="$(curl --fail-with-body -sS -m "${LUA_TEST_TIMEOUT:-600}" -X POST "$NODE/~lua@5.3a/venuetest" \
  -H 'content-type: application/lua' --data-binary @"$BUNDLE")"
printf '%s\n' "$RESULT"
if ! grep -Eq '(^|[^0-9])0 failed([^0-9]|$)' <<<"$RESULT"; then
  echo "venue suite did not report zero failures" >&2
  exit 1
fi
