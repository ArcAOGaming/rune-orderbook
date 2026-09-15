# Rune Orderbook

The standalone Orderbook product: matching and custody contracts, a browser
client, shared market UI, and its own landing application.

```bash
npm ci
npm test
npm run dev
```

The phase-one app is deliberately read-only. It proves that a fresh clone can
read and render the public venue without carrying Rune Realm's game context.
Signed custody, order entry, charts, and the complete trading floor move here
only after `rune-ao` has a product-neutral release.

## Layout

- `contracts/` — focused Lua matching engine, custody process, JSON support,
  constants snapshot, and contract suite.
- `packages/client/` — public read-only venue client and protocol types.
- `packages/ui/` — shared React market overview used by the standalone app.
- `app/` — independent Vite landing application.
- `provenance/` — the exact source commit and orderbook settings used at the
  split. `test/constants-drift.test.mjs` keeps the Lua snapshot aligned.

Run the complete Lua suite against a free public Luerl device with
`npm run test:contract`. No wallet is used and no process is deployed.
That networked suite is manual only; pull requests run the deterministic
constants, type, and app build checks without contacting a live service.

The complete design and protocol record remains in [ORDERBOOK.md](ORDERBOOK.md).
