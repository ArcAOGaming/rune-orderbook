# Rune Orderbook

The standalone Orderbook product: matching and custody contracts, a browser
client, shared market UI, and its own landing application.

```bash
npm ci
npm test
npm run dev
```

The app can run as a standalone product against any compatible venue process.
It includes wallet connection, deposits and withdrawals, limit/IOC/FOK/post-only
order entry, live depth, fills, candles, positions, and order cancellation. The
same terminal is exported for embedding in products such as Rune Realm.

## Layout

- `contracts/` - focused Lua matching engine, custody process, JSON support,
  constants snapshot, and contract suite.
- `packages/client/` - signed venue client and public protocol types.
- `packages/ui/` - reusable React trading terminal and styles.
- `app/` - independent Vite landing page and standalone terminal.
- `provenance/` - the exact source commit and orderbook settings used at the
  split. `test/constants-drift.test.mjs` keeps the Lua snapshot aligned.

The complete history-filter recipe and rewritten checkpoint parent are recorded
in `split-provenance.json`.

Run the complete Lua suite against a free public Luerl device with
`npm run test:contract`. No wallet is used and no process is deployed.
That networked suite is manual only; pull requests run the deterministic
constants, type, and app build checks without contacting a live service.

The complete design and protocol record remains in [ORDERBOOK.md](ORDERBOOK.md).
