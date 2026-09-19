import test from 'node:test';
import assert from 'node:assert/strict';
import { planRoute, ShardedVenue, splitOrderId, isVault } from '../packages/client/src/sharded.ts';

const VAULT = 'V'.repeat(43);
const FIRE = 'F'.repeat(43);
const SCROLL = 'S'.repeat(43);
const ALICE = 'A'.repeat(43);

test('funds already at the destination need no route', () => {
  assert.equal(planRoute({ fire: 500n }, 'gold', 300n, 'fire', [{ op: 'place' }]), null);
});

test('one source is one move carrying the order', () => {
  const route = planRoute({ vault: 1000n }, 'gold', 300n, 'fire', [{ op: 'place' }]);
  assert.deepEqual(route, { first: 'vault', ops: [
    { op: 'move', asset: 'gold', quantity: '300', to: 'fire', then: [{ op: 'place' }] },
  ] });
});

test('what the destination already holds only tops up the shortfall', () => {
  const route = planRoute({ fire: 100n, vault: 1000n }, 'gold', 300n, 'fire', [{ op: 'place' }]);
  assert.equal(route.ops[0].quantity, '200');
});

test('several sources chain, each hop carrying everything so far', () => {
  const route = planRoute({ scroll: 200n, vault: 150n }, 'gold', 300n, 'fire', [{ op: 'place' }]);
  // Largest first: scroll gives 200, then the vault 100, then on to fire.
  assert.equal(route.first, 'scroll');
  const [hop1] = route.ops;
  assert.deepEqual([hop1.quantity, hop1.to], ['200', 'vault']);
  const [hop2] = hop1.then;
  assert.deepEqual([hop2.quantity, hop2.to], ['300', 'fire']);
  assert.deepEqual(hop2.then, [{ op: 'place' }]);
});

test('not enough anywhere is refused before anything is signed', () => {
  assert.throws(() => planRoute({ vault: 10n }, 'gold', 300n, 'fire', []), /300 is needed/);
});

test('order ids carry their pair', () => {
  assert.deepEqual(splitOrderId('fire_berry_gold~O12'), { pair: 'fire_berry_gold', order: 'O12' });
  assert.throws(() => splitOrderId('O12'), /does not name its pair/);
});

function network(published) {
  const sent = [];
  return {
    sent,
    transport: {
      async read(process, key) { return published[process]?.[key] ?? null; },
      async send(process, tags, options) {
        sent.push({ process, tags: Object.fromEntries(tags.map((t) => [t.name, t.value])), options });
        return { ok: true };
      },
    },
  };
}

const published = {
  [VAULT]: {
    vaultinfo: { Funding: 'game', Name: 'TEST-Vault', Sealed: true, Paused: false,
      PauseScope: 'trading', Assets: {} },
    vaultpairs: {
      fire_berry_gold: { process: FIRE, base: 'fire_berry', quote: 'gold' },
      scroll_gold: { process: SCROLL, base: 'scroll', quote: 'gold' },
    },
    [`balance-${ALICE}`]: { free: { gold: '5000' } },
  },
  [FIRE]: {
    pairinfo: { Base: 'fire_berry', Quote: 'gold', Status: 'open', Tick: 1, Lot: 1,
      MinValue: 1, MaxPrice: 1e6, MaxQuantity: 1e6, TakerBps: 0, BandBps: 0, CreationCost: 0 },
    [`balance-${ALICE}`]: { free: { gold: '100' },
      orders: [{ id: 'O1', market: 'fire_berry/gold', side: 'buy' }], fills: [] },
  },
  [SCROLL]: {
    pairinfo: { Base: 'scroll', Quote: 'gold', Status: 'open', Tick: 1, Lot: 1,
      MinValue: 1, MaxPrice: 1e6, MaxQuantity: 1e6, TakerBps: 30, BandBps: 0, CreationCost: 0 },
    [`balance-${ALICE}`]: { free: { gold: '0' }, orders: [{ id: 'O1', market: 'scroll/gold' }] },
  },
};

test('a vault is recognised by its published info', async () => {
  const { transport } = network(published);
  assert.equal(await isVault(transport, VAULT), true);
  assert.equal(await isVault(transport, FIRE), false);
});

test('a position is summed over the vault and every pair, ids made unique', async () => {
  const { transport } = network(published);
  const venue = new ShardedVenue(transport, VAULT);
  const position = await venue.position(ALICE);
  assert.equal(position.free.gold, '5100');
  assert.deepEqual(position.locations.gold, { vault: '5000', fire_berry_gold: '100' });
  assert.deepEqual(position.orders.map((o) => o.id).sort(),
    ['fire_berry_gold~O1', 'scroll_gold~O1']);
});

test('an order the pair can fund goes straight to the pair', async () => {
  const { transport, sent } = network(published);
  const venue = new ShardedVenue(transport, VAULT);
  await venue.place(ALICE, 'buy', 'fire_berry', 10, 5);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].process, FIRE);
  assert.equal(sent[0].tags.Action, 'Order.Place');
});

test('an order the pair cannot fund is ONE batch from where the Gold is', async () => {
  const { transport, sent } = network(published);
  const venue = new ShardedVenue(transport, VAULT);
  await venue.place(ALICE, 'buy', 'scroll', 1000, 2);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].process, VAULT);
  assert.equal(sent[0].tags.Action, 'Batch');
  const [move] = JSON.parse(sent[0].tags.Ops);
  // 2,000 notional plus a 30 bps taker fee, rounded up.
  assert.deepEqual([move.op, move.asset, move.quantity, move.to], ['move', 'gold', '2006', 'scroll_gold']);
  assert.equal(move.then[0].op, 'place');
});

test('cancel goes to the pair that owns the order, with its own id', async () => {
  const { transport, sent } = network(published);
  const venue = new ShardedVenue(transport, VAULT);
  await venue.cancel('scroll_gold~O1');
  assert.equal(sent[0].process, SCROLL);
  assert.equal(sent[0].tags.OrderId, 'O1');
});

test('a withdrawal gathers from the pairs through the vault in one signature', async () => {
  const { transport, sent } = network(published);
  const venue = new ShardedVenue(transport, VAULT);
  await venue.withdraw(ALICE, 'gold', 5100);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].process, FIRE);
  const [move] = JSON.parse(sent[0].tags.Ops);
  assert.deepEqual([move.to, move.quantity, move.then[0].op], ['vault', '100', 'withdraw']);
});

test('a reply comes back in the single venue shape, with the summed account', async () => {
  const { transport } = network(published);
  transport.send = async () => ({ results: [{ op: 'place', result: { order: { id: 'O5' }, fills: [{ id: 'F2' }] } }] });
  const venue = new ShardedVenue(transport, VAULT);
  const reply = await venue.place(ALICE, 'buy', 'fire_berry', 10, 5);
  assert.equal(reply.order.order.id, 'fire_berry_gold~O5');
  assert.equal(reply.order.fills[0].id, 'fire_berry_gold~F2');
  assert.equal(reply.account.free.gold, '5100');
});

test('an amend that grows a bid gathers the extra Gold and amends on arrival', async () => {
  const book = structuredClone(published);
  book[FIRE][`balance-${ALICE}`] = { free: { gold: '0' }, fills: [],
    orders: [{ id: 'O1', market: 'fire_berry/gold', side: 'buy', price: 10, remaining: 5, lot: 1 }] };
  const { transport, sent } = network(book);
  const venue = new ShardedVenue(transport, VAULT);
  await venue.amend('fire_berry_gold~O1', { quantity: 20 }, {}, ALICE);
  assert.equal(sent[0].process, VAULT);
  const [move] = JSON.parse(sent[0].tags.Ops);
  assert.deepEqual([move.quantity, move.to, move.then[0].op, move.then[0].order], ['150', 'fire_berry_gold', 'amend', 'O1']);
});

test('an amend that shrinks goes straight to its pair', async () => {
  const book = structuredClone(published);
  book[FIRE][`balance-${ALICE}`].orders = [{ id: 'O1', market: 'fire_berry/gold', side: 'buy', price: 10, remaining: 5, lot: 1 }];
  const { transport, sent } = network(book);
  await new ShardedVenue(transport, VAULT).amend('fire_berry_gold~O1', { quantity: 2 }, {}, ALICE);
  assert.equal(sent[0].process, FIRE);
  assert.equal(sent[0].tags.Action, 'Order.Amend');
});

test('a failed registry read is an error, never a cached empty venue', async () => {
  let reads = 0;
  const book = structuredClone(published);
  const { transport } = network(book);
  const read = transport.read;
  transport.read = async (process, key) => {
    if (key === 'vaultpairs') { reads += 1; if (reads === 1) return null; }
    return read(process, key);
  };
  const venue = new ShardedVenue(transport, VAULT);
  await assert.rejects(venue.book(), /not published its markets/);
  // The next read goes back to the vault instead of serving a cached nothing.
  const markets = await venue.markets();
  assert.deepEqual(Object.keys(markets).sort(), ['fire_berry/gold', 'scroll/gold']);
});

test('concurrent callers share one registry read', async () => {
  let reads = 0;
  const { transport } = network(published);
  const read = transport.read;
  transport.read = async (process, key) => { if (key === 'vaultpairs') reads += 1; return read(process, key); };
  const venue = new ShardedVenue(transport, VAULT);
  await Promise.all([venue.markets(), venue.position(ALICE), venue.markets()]);
  assert.equal(reads, 1);
});

test('a failed vault check is retried, not remembered as "not a vault"', async () => {
  const { transport } = network(published);
  const read = transport.read;
  let fail = true;
  transport.read = async (process, key) => {
    if (key === 'vaultinfo' && fail) { fail = false; throw new Error('timeout'); }
    return read(process, key);
  };
  const pid = 'W'.repeat(43);
  published[pid] = published[VAULT];
  await assert.rejects(isVault(transport, pid), /timeout/);
  assert.equal(await isVault(transport, pid), true);
});

test('chart backfill reads pairhistory, and pairstate from a pair that predates it', async () => {
  const { transport } = network({
    ...published,
    [FIRE]: { ...published[FIRE], pairhistory: [[1790000000, 500, 3, 1], [1790000005, 498, 2, 0]] },
    [SCROLL]: { ...published[SCROLL], pairstate: { book: { fills: [
      { id: 'F1', market: 'scroll/gold', price: 40, quantity: 1, takerSide: 'sell', filledAt: 1790000001000 },
    ] } } },
  });
  const fills = await new ShardedVenue(transport, VAULT).historyFills();
  const fire = fills.filter((fill) => fill.market === 'fire_berry/gold')
    .map(({ price, quantity, takerSide, filledAt }) => [filledAt, price, quantity, takerSide]);
  assert.deepEqual(fire, [[1790000000000, 500, 3, 'buy'], [1790000005000, 498, 2, 'sell']]);
  assert.deepEqual(fills.filter((fill) => fill.market === 'scroll/gold').map((fill) => fill.id), ['F1']);
});
