/**
 * The sharded venue, seen from a browser: one vault, many pair processes,
 * presented as the single venue every screen already knows how to draw.
 * ORDERBOOK.md §16.
 *
 * A caller hands over a vault id and gets the same reads (info, markets, book,
 * tape, candles, supply, position) and writes (place, amend, cancel,
 * cancelAll, withdraw, deposit) the one-process venue has. Underneath:
 *
 *   - reads fan out to every pair the vault's registry (`vaultpairs`) lists;
 *   - a position is the SUM of what an account holds at the vault and at every
 *     pair, with the order ids made unique across pairs;
 *   - a write goes to whichever process holds the funds, and when they are
 *     somewhere else the client builds ONE signed batch that moves them there
 *     and runs the order on arrival. The player signs once; the contract
 *     carries the rest.
 *
 * No imports: transport is injected, so the game UI and the standalone app
 * can both use this over their own signers.
 */

export interface ShardedTransport {
  /** A published key as JSON, or null when absent (HTML at 200 counts as absent). */
  read<T>(process: string, key: string): Promise<T | null>;
  send<T>(process: string, tags: Array<{ name: string; value: string }>,
    options?: { requiredOutbox?: boolean }): Promise<T>;
}

export type Side = 'buy' | 'sell';
export interface OrderOptions { tif?: string; stp?: string; expiresIn?: number }

export interface PairEntry { id: string; process: string; base: string; quote: string }
interface PairInfo {
  Pair: string; Market: string; Base: string; Quote: string; Status: string;
  Tick: number; Lot: number; MinValue: number; MaxPrice: number; MaxQuantity: number;
  TakerBps: number; BandBps: number; CreationCost: number; Paused: boolean;
}
interface VaultInfo {
  Name: string; Funding: 'token' | 'game'; Game?: string; Sealed: boolean;
  Paused: boolean; PauseScope: string;
  Assets: Record<string, { id: string; name: string; kind: 'token' | 'game'; process?: string;
    ticker?: string; denomination?: string }>;
}
interface Row { account?: string; free?: Record<string, string>; orders?: Order[]; fills?: Fill[] }
export interface Order {
  id: string; market: string; item: string; side: Side; price: number; quantity: number;
  remaining: number; lot: number; createdAt: number; expiresAt: number;
}
export interface Fill {
  id: string; market: string; item: string; price: number; quantity: number; fee: number;
  buyer: string; seller: string; takerSide: Side; filledAt: number;
}
export interface ShardedPosition {
  account: string;
  /** Free per asset, summed over the vault and every pair. */
  free: Record<string, string>;
  /** Where that free balance actually is: asset -> location -> amount. */
  locations: Record<string, Record<string, string>>;
  orders: Order[];
  fills: Fill[];
}

/** A location is `vault` or a pair id. */
const VAULT = 'vault';
/** Order ids are only unique inside one pair, so ours carry the pair id. */
const SEPARATOR = '~';
/** A chain may cross at most this many processes (custody.lua MAX_HOPS). */
const MAX_SOURCES = 4;

const tags = (values: Record<string, string>) =>
  Object.entries(values).map(([name, value]) => ({ name, value }));
const big = (value: unknown) => {
  try { return BigInt(String(value ?? '0')); } catch { return 0n; }
};
const unwrap = <T>(value: T): T => {
  const error = (value as { error?: unknown } | null)?.error;
  if (error) throw new Error(String(error));
  return value;
};
let sequence = 0;
const actionId = (kind: string) => `${kind}-${Date.now().toString(36)}-${(++sequence).toString(36)}`;

/** An order-book result with its order and fill ids made unique across pairs. */
function withPairIds(pair: string, result: Record<string, unknown> | undefined) {
  if (!result) return result;
  const order = result.order as { id?: string } | undefined;
  const fills = result.fills as Array<{ id?: string }> | undefined;
  return {
    ...result,
    ...(order?.id ? { order: { ...order, id: `${pair}${SEPARATOR}${order.id}` } } : {}),
    ...(Array.isArray(fills) ? { fills: fills.map((f) => ({ ...f, id: `${pair}${SEPARATOR}${f.id}` })) } : {}),
  };
}

export function splitOrderId(id: string): { pair: string; order: string } {
  const at = id.indexOf(SEPARATOR);
  if (at <= 0) throw new Error(`Order id ${id} does not name its pair`);
  return { pair: id.slice(0, at), order: id.slice(at + 1) };
}

/** Is this process a vault? Cached per process: it cannot change. */
const vaultCache = new Map<string, Promise<boolean>>();
export function isVault(transport: ShardedTransport, process: string): Promise<boolean> {
  let known = vaultCache.get(process);
  if (!known) {
    known = transport.read<VaultInfo>(process, 'vaultinfo')
      .then((info) => Boolean(info && typeof info === 'object' && 'Funding' in info))
      .catch(() => false);
    vaultCache.set(process, known);
  }
  return known;
}

/**
 * The route that gets `amount` of `asset` to `destination` and then runs
 * `final` there: a nested batch, first message to the first source.
 *
 * Pure, so it can be tested without a network. `held` is location -> free.
 * Returns null when the destination already holds enough (send `final`
 * straight there), or throws when the account does not hold enough anywhere.
 */
export function planRoute(
  held: Record<string, bigint>, asset: string, amount: bigint,
  destination: string, final: unknown[],
): { first: string; ops: unknown[] } | null {
  const already = held[destination] ?? 0n;
  if (already >= amount) return null;
  let short = amount - already;
  const sources = Object.entries(held)
    .filter(([where, n]) => where !== destination && n > 0n)
    .sort((a, b) => (a[1] === b[1] ? a[0].localeCompare(b[0]) : a[1] > b[1] ? -1 : 1));
  const picked: Array<[string, bigint]> = [];
  for (const [where, n] of sources) {
    if (short <= 0n) break;
    const take = n < short ? n : short;
    picked.push([where, take]);
    short -= take;
  }
  if (short > 0n) {
    const total = Object.values(held).reduce((sum, n) => sum + n, 0n);
    throw new Error(`You hold ${total} free ${asset}; ${amount} is needed`);
  }
  if (picked.length > MAX_SOURCES) {
    throw new Error(`Your ${asset} is spread over ${picked.length} markets; consolidate it first`);
  }
  // Build from the destination backwards: each hop carries everything picked
  // up so far, and the last hop runs `final` where it lands.
  let then: unknown[] = final;
  let target = destination;
  let carried = picked.reduce((sum, [, n]) => sum + n, 0n);
  for (let i = picked.length - 1; i >= 0; i -= 1) {
    const [where, take] = picked[i];
    const move = { op: 'move', asset, quantity: carried.toString(), to: target, then };
    carried -= take;
    if (i === 0) return { first: where, ops: [move] };
    then = [move];
    target = where;
  }
  return null;
}

export class ShardedVenue {
  private pairCache?: { at: number; pairs: Record<string, PairEntry> };
  private readonly transport: ShardedTransport;
  readonly vault: string;

  constructor(transport: ShardedTransport, vault: string) {
    this.transport = transport;
    this.vault = vault;
  }

  private async readOr<T>(process: string, key: string, fallback: T): Promise<T> {
    try { return (await this.transport.read<T>(process, key)) ?? fallback; }
    catch { return fallback; }
  }

  /** The registry. Re-read every 30 s; pairs are added, never re-pointed. */
  async pairs(): Promise<Record<string, PairEntry>> {
    if (this.pairCache && Date.now() - this.pairCache.at < 30_000) return this.pairCache.pairs;
    const listed = await this.readOr<Record<string, Omit<PairEntry, 'id'>>>(this.vault, 'vaultpairs', {});
    const pairs: Record<string, PairEntry> = {};
    for (const [id, row] of Object.entries(Array.isArray(listed) ? {} : listed)) {
      if (row && typeof row.process === 'string') pairs[id] = { id, ...row };
    }
    this.pairCache = { at: Date.now(), pairs };
    return pairs;
  }

  private async pairFor(item: string): Promise<PairEntry> {
    const pairs = await this.pairs();
    const found = pairs[item] ?? Object.values(pairs).find((pair) =>
      pair.base === item || `${pair.base}/${pair.quote}` === item);
    if (!found) throw new Error(`No market for ${item}`);
    return found;
  }

  /** One read per pair, keyed by market id. */
  private async perMarket<T>(key: string): Promise<Record<string, T>> {
    const out: Record<string, T> = {};
    await Promise.all(Object.values(await this.pairs()).map(async (pair) => {
      const value = await this.readOr<T | null>(pair.process, key, null);
      if (value !== null) out[`${pair.base}/${pair.quote}`] = value;
    }));
    return out;
  }

  async info() {
    const info = await this.transport.read<VaultInfo>(this.vault, 'vaultinfo');
    if (!info) throw new Error('The vault has not published its info yet');
    const markets: Record<string, { id: string; base: string; quote: string; status: string }> = {};
    for (const [id, row] of Object.entries(await this.markets())) {
      markets[id] = { id, base: row.base, quote: row.quote, status: row.status };
    }
    return {
      Name: info.Name, Mode: info.Funding === 'game' ? 'internal' as const : 'external' as const,
      Sealed: info.Sealed, GameProcess: info.Game, Paused: info.Paused,
      WithdrawalsOpen: !info.Paused || info.PauseScope !== 'all',
      Assets: info.Assets, Markets: markets,
    };
  }

  async markets() {
    const infos = await this.perMarket<PairInfo>('pairinfo');
    const out: Record<string, {
      id: string; base: string; quote: string; tick: number; lot: number; minValue: number;
      maxPrice: number; maxQuantity: number; takerBps: number; bandBps: number;
      creationCost: number; status: string;
    }> = {};
    for (const [id, row] of Object.entries(infos)) {
      out[id] = {
        id, base: row.Base, quote: row.Quote, tick: Number(row.Tick), lot: Number(row.Lot),
        minValue: Number(row.MinValue), maxPrice: Number(row.MaxPrice),
        maxQuantity: Number(row.MaxQuantity), takerBps: Number(row.TakerBps),
        bandBps: Number(row.BandBps), creationCost: Number(row.CreationCost) || 0,
        status: row.Status,
      };
    }
    return out;
  }

  book<T>() { return this.perMarket<T>('pairbook'); }
  tape<T>() { return this.perMarket<T>('pairtape'); }
  candles<T>() { return this.perMarket<T>('paircandles'); }

  /** The raw fill ring each pair keeps for its own restore, for chart backfill. */
  async historyFills(): Promise<Fill[]> {
    const states = await this.perMarket<{ book?: { fills?: Fill[] } }>('pairstate');
    return Object.values(states).flatMap((state) => state?.book?.fills ?? []);
  }

  /** Per-asset custody summed over the vault and every pair. */
  async supply() {
    const vault = await this.readOr<Record<string, { backing?: string; free?: string;
      scale?: string }>>(this.vault, 'vaultsupply', {});
    const pairs = await this.perMarket<Record<string, Record<string, string>>>('pairsupply');
    const out: Record<string, { free: string; escrow: string; locked: string; held: string;
      fees: string; scale: string; backingHeld: string }> = {};
    for (const [asset, row] of Object.entries(vault)) {
      let free = big(row.free); let escrow = 0n; let locked = 0n; let fees = 0n;
      for (const supply of Object.values(pairs)) {
        const at = supply?.[asset];
        if (!at) continue;
        free += big(at.free); escrow += big(at.escrow); locked += big(at.locked); fees += big(at.fees);
      }
      const scale = big(row.scale) || 1n;
      out[asset] = {
        free: free.toString(), escrow: escrow.toString(), locked: locked.toString(),
        held: (free + escrow + locked).toString(), fees: fees.toString(),
        scale: scale.toString(), backingHeld: (big(row.backing) / scale).toString(),
      };
    }
    return out;
  }

  async position(address: string): Promise<ShardedPosition> {
    const pairs = Object.values(await this.pairs());
    const [atVault, ...atPairs] = await Promise.all([
      this.readOr<Row>(this.vault, `balance-${address}`, {}),
      ...pairs.map((pair) => this.readOr<Row>(pair.process, `balance-${address}`, {})),
    ]);
    const locations: Record<string, Record<string, string>> = {};
    const free: Record<string, bigint> = {};
    const add = (where: string, row: Row) => {
      for (const [asset, amount] of Object.entries(row.free && !Array.isArray(row.free) ? row.free : {})) {
        if (big(amount) <= 0n) continue;
        (locations[asset] ??= {})[where] = String(amount);
        free[asset] = (free[asset] ?? 0n) + big(amount);
      }
    };
    add(VAULT, atVault);
    const orders: Order[] = [];
    const fills: Fill[] = [];
    pairs.forEach((pair, index) => {
      const row = atPairs[index];
      add(pair.id, row);
      for (const order of row.orders ?? []) orders.push({ ...order, id: `${pair.id}${SEPARATOR}${order.id}` });
      for (const fill of row.fills ?? []) fills.push({ ...fill, id: `${pair.id}${SEPARATOR}${fill.id}` });
    });
    fills.sort((a, b) => b.filledAt - a.filledAt);
    return {
      account: address, locations, orders, fills,
      free: Object.fromEntries(Object.entries(free).map(([asset, n]) => [asset, n.toString()])),
    };
  }

  private held(position: ShardedPosition, asset: string): Record<string, bigint> {
    const out: Record<string, bigint> = {};
    for (const [where, amount] of Object.entries(position.locations[asset] ?? {})) out[where] = big(amount);
    return out;
  }

  private processOf(location: string, pairs: Record<string, PairEntry>) {
    if (location === VAULT) return this.vault;
    const pair = pairs[location];
    if (!pair) throw new Error(`Unknown location ${location}`);
    return pair.process;
  }

  /**
   * A contract reply in the single venue's shape, plus the account summed over
   * every location -- a pair's own `account` only knows that pair, and a
   * caller that cached it would forget the rest of the player's funds.
   */
  private async shaped<T>(address: string | undefined, raw: unknown,
                          extra: (first: Record<string, unknown> | undefined) => Record<string, unknown>) {
    const reply = unwrap(raw as { results?: Array<{ op?: string; result?: Record<string, unknown> }> });
    const first = reply?.results?.[0]?.result;
    const account = address ? await this.position(address) : undefined;
    return { ...(reply as object), ...extra(first), ...(account ? { account } : {}) } as unknown as T;
  }

  /**
   * Send `final` to `destination`, first gathering `amount` of `asset` there.
   * `routed` says the funds had to move: the step then runs one hop later, at
   * the destination, and its result is not in this reply.
   */
  private async routed<T>(
    address: string, asset: string, amount: bigint, destination: string,
    final: Record<string, unknown>, direct: Record<string, string>,
    extra: (first: Record<string, unknown> | undefined) => Record<string, unknown>,
  ): Promise<T> {
    const pairs = await this.pairs();
    const position = await this.position(address);
    const route = planRoute(this.held(position, asset), asset, amount, destination, [final]);
    if (!route) {
      return this.shaped<T>(address, await this.transport.send(this.processOf(destination, pairs),
        tags(direct), { requiredOutbox: direct.Action === 'Withdraw' }), extra);
    }
    return this.shaped<T>(address, await this.transport.send(this.processOf(route.first, pairs), tags({
      Action: 'Batch', Ops: JSON.stringify(route.ops), ActionId: actionId('route'),
    }), { requiredOutbox: true }), () => ({ routed: true, route: route.ops }));
  }

  /**
   * Place an order, moving the funds it needs to its pair first if they are
   * at the vault or another pair. One signature either way.
   */
  async place<T>(address: string, side: Side, item: string, price: string | number,
                 quantity: string | number, options: OrderOptions = {}): Promise<T> {
    const pair = await this.pairFor(item);
    const market = (await this.markets())[`${pair.base}/${pair.quote}`];
    const qty = big(quantity);
    const lot = big(market?.lot ?? 1) || 1n;
    let asset = pair.base;
    let need = qty * lot;
    if (side === 'buy') {
      // The escrow, plus the most a taking buy could owe in fees, plus the
      // flat creation cost -- the same check `placeOrder` makes up front.
      const notional = big(price) * qty;
      const bps = big(market?.takerBps ?? 0);
      asset = pair.quote;
      need = notional + (notional * bps + 9999n) / 10000n + big(market?.creationCost ?? 0);
    }
    const order: Record<string, string> = {
      side, price: String(price), quantity: String(quantity),
      ...(options.tif ? { tif: options.tif } : {}),
      ...(options.stp ? { stp: options.stp } : {}),
      ...(options.expiresIn ? { expiresIn: String(Math.floor(options.expiresIn)) } : {}),
    };
    return this.routed<T>(address, asset, need, pair.id, { op: 'place', ...order }, {
      Action: 'Order.Place', Side: side, Price: String(price), Quantity: String(quantity),
      ActionId: actionId('order'),
      ...(options.tif ? { Tif: options.tif } : {}),
      ...(options.stp ? { Stp: options.stp } : {}),
      ...(options.expiresIn ? { ExpiresIn: String(Math.floor(options.expiresIn)) } : {}),
    }, (first) => ({ order: withPairIds(pair.id, first) }));
  }

  async amend<T>(orderId: string, changes: { price?: string | number; quantity?: string | number },
                 options: OrderOptions = {}, address?: string): Promise<T> {
    const { pair, order } = splitOrderId(orderId);
    const pairs = await this.pairs();
    return this.shaped<T>(address, await this.transport.send(this.processOf(pair, pairs), tags({
      Action: 'Order.Amend', OrderId: order, ActionId: actionId('amend'),
      ...(changes.price !== undefined ? { Price: String(changes.price) } : {}),
      ...(changes.quantity !== undefined ? { Quantity: String(changes.quantity) } : {}),
      ...(options.tif ? { Tif: options.tif } : {}),
      ...(options.stp ? { Stp: options.stp } : {}),
    })), (first) => ({ order: withPairIds(pair, first) }));
  }

  async cancel<T>(orderId: string, address?: string): Promise<T> {
    const { pair, order } = splitOrderId(orderId);
    const pairs = await this.pairs();
    return this.shaped<T>(address, await this.transport.send(this.processOf(pair, pairs), tags({
      Action: 'Order.Cancel', OrderId: order, ActionId: actionId('cancel'),
    })), (first) => ({ cancelled: first }));
  }

  /** One message per pair that has orders open; each is its own signature. */
  async cancelAll<T>(address: string, item?: string): Promise<T> {
    const pairs = await this.pairs();
    const targets = item ? [(await this.pairFor(item)).id]
      : [...new Set((await this.position(address)).orders.map((o) => splitOrderId(o.id).pair))];
    const cancelledIds: string[] = [];
    for (const id of targets) {
      const reply = unwrap(await this.transport.send<{ results?: Array<{
        result?: { cancelledIds?: string[] } }> }>(this.processOf(id, pairs), tags({
        Action: 'Order.CancelAll', ActionId: actionId('cancel-all'),
      })));
      for (const row of reply?.results?.[0]?.result?.cancelledIds ?? []) {
        cancelledIds.push(`${id}${SEPARATOR}${row}`);
      }
    }
    return { cancelled: { cancelledIds }, account: await this.position(address) } as unknown as T;
  }

  /** Housekeeping, on every pair: anyone may call it, nobody is paid to. */
  async maintain<T>(limit = 25): Promise<T> {
    let expired = 0;
    for (const pair of Object.values(await this.pairs())) {
      const reply = unwrap(await this.transport.send<{ expired?: number }>(pair.process, tags({
        Action: 'Order.Maintain', Limit: String(Math.max(1, Math.floor(limit))),
      })));
      expired += Number(reply?.expired ?? 0) || 0;
    }
    return { expired } as unknown as T;
  }

  /** Out of the venue, gathering from wherever the balance is. One signature. */
  withdraw<T>(address: string, asset: string, quantity: string | number): Promise<T> {
    return this.routed<T>(address, asset, big(quantity), VAULT,
      { op: 'withdraw', asset, quantity: String(quantity) },
      { Action: 'Withdraw', Asset: asset, Quantity: String(quantity) },
      (first) => ({ withdrawal: first?.withdrawal
        ? { id: String(first.withdrawal), status: 'pending' } : undefined }));
  }

  /**
   * Token vault only: Transfer to the vault. Naming a market sends the deposit
   * straight on to that pair in the vault's same slot.
   */
  depositToken<T>(tokenProcess: string, quantity: string | number, item?: string): Promise<T> {
    return (async () => {
      const pair = item ? await this.pairFor(item) : null;
      return this.transport.send<T>(tokenProcess, tags({
        Action: 'Transfer', Recipient: this.vault, Quantity: String(quantity),
        ...(pair ? { 'X-Pair': pair.id } : {}),
      }), { requiredOutbox: true });
    })();
  }
}
