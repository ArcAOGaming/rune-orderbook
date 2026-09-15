# Rune Orderbook repository rules

- This repository owns the orderbook engine, venue custody process, venue
  client, shared trading UI, and standalone product.
- Every deployed process and token remains prefixed `TEST-` until release.
- Narrow every external numeric tag through an integer conversion and test raw
  serialized replies; decoded JSON numbers do not prove integer storage.
- Never use `Target` as a tag name. Identity comes only from a real signature
  commitment, never from a tag or hmac commitment.
- Bound every retained list at insertion. Published state is paid on every
  message, whether or not a handler touched that key.
- Phase one is read-only in the browser. Do not add signed actions by copying
  Rune Realm transport code; consume a released `rune-ao` API first.
- `npm test`, `npm run build`, and `npm run test:contract` are the verification
  surfaces. Keep changes surgical.
