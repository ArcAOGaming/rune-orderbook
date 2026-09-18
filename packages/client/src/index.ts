import { createAoClient, type AoBrowserClient } from '@runerealm/ao/client';
import { activeAddress } from '@runerealm/ao/wallet';
import { isVault, ShardedVenue, type ShardedTransport } from './sharded';
export {
  isVault, planRoute, ShardedVenue, splitOrderId,
  type ShardedPosition, type ShardedTransport,
} from './sharded';
export {
  activeAddress, configureWallet, connectWallet, disconnectWallet, restoreWallet,
  walletAvailability, type WalletAvailability, type WalletConnection, type WalletProviderId,
} from '@runerealm/ao/wallet';

export type VenueSide = 'buy' | 'sell';
export type VenueTif = 'GTC' | 'IOC' | 'FOK' | 'PostOnly';
export type VenueStp = 'CancelResting' | 'Reject' | 'CancelBoth';
export interface VenueLevel { price: number; quantity: number; orders: number; house?: boolean }
export interface VenueCandle { d: number; o: number; h: number; l: number; c: number; v: number; g: number; n: number }
export interface VenueMarketBook {
  id: string; base: string; quote: string; status: string; tick: number; lot: number;
  bestBid?: number; bestAsk?: number; depth: { bids: VenueLevel[]; asks: VenueLevel[] };
  band?: { low: number; high: number; bps: number }; candles?: VenueCandle[];
}
export type VenueBook = Record<string, VenueMarketBook>;
export type VenueTrade = [at: number, price: number, quantity: number, takerBought: number];
export type VenueTape = Record<string, VenueTrade[]>;
export type VenueIntradayCandle = [number, number, number, number, number, number, number, number];
export type VenueCandles = Record<string, { '60'?: VenueIntradayCandle[]; '300'?: VenueIntradayCandle[] }>;
interface VenuePairPublication {
  id: string; base: string; quote: string;
  book: string; candles: string; tape: string;
}
export interface VenueAsset {
  id: string; name: string; kind: 'token' | 'game'; process?: string;
  ticker?: string; denomination?: string;
}
export interface VenueInfo {
  Name: string; Mode: 'internal' | 'external' | ''; Sealed: boolean; GameProcess?: string;
  Paused: boolean; WithdrawalsOpen: boolean; Assets: Record<string, VenueAsset>;
  Markets: Record<string, { id: string; base: string; quote: string; status: string }>;
}
export interface VenueMarketConfig {
  id: string; base: string; quote: string; tick: number; lot: number; minValue: number;
  maxPrice: number; maxQuantity: number; takerBps: number; bandBps: number;
  creationCost: number; status: string;
}
export interface VenueOrder {
  id: string; market: string; item: string; side: VenueSide; price: number;
  quantity: number; remaining: number; lot: number; createdAt: number; expiresAt: number;
}
export interface VenueFill {
  id: string; market: string; item: string; price: number; quantity: number; fee: number;
  buyer: string; seller: string; takerSide: VenueSide; filledAt: number;
}
export interface VenuePosition {
  account: string; free: Record<string, string>; orders: VenueOrder[]; fills: VenueFill[];
}
export interface VenueSupplyRow {
  free: string; escrow: string; locked: string; held: string; fees: string;
  scale: string; backingHeld: string;
}
export interface OrderOptions { tif?: VenueTif; stp?: VenueStp; expiresIn?: number }
export interface VenueSendOptions { data?: string; requiredOutbox?: boolean }
export type VenueSend = <T>(
  process: string,
  tags: Array<{ name: string; value: string }>,
  options?: VenueSendOptions,
) => Promise<T>;
export interface VenueClientConfiguration {
  node: string; process: string; send?: VenueSend;
  /** Who is signing; routing a sharded order needs to know where their funds are. */
  address?: () => Promise<string | null>;
}

const PROCESS_ID = /^[A-Za-z0-9_-]{43}$/;
let sequence = 0;
const actionId = (kind: string) => `${kind}-${Date.now().toString(36)}-${(++sequence).toString(36)}`;
const messageTags = (values: Record<string, string>) =>
  Object.entries(values).map(([name, value]) => ({ name, value }));
const unwrap = <T>(value: T & { error?: unknown }): T => {
  if (value && typeof value === 'object' && value.error) throw new Error(String(value.error));
  return value;
};

export class VenueClient {
  readonly node: string;
  readonly process: string;
  readonly ao: AoBrowserClient;
  private readonly send: VenueSend;
  private readonly address: () => Promise<string | null>;
  private sharded?: Promise<ShardedVenue | null>;

  constructor({ node, process, send, address }: VenueClientConfiguration) {
    this.ao = createAoClient({ node, process });
    this.node = this.ao.node;
    this.process = this.ao.process;
    this.send = send ?? (<T,>(target: string, tags: Array<{ name: string; value: string }>,
      options: VenueSendOptions = {}) => createAoClient({ node: this.node, process: target })
        .send<T>(tags, options));
    this.address = address ?? activeAddress;
  }

  /**
   * A vault id means the sharded venue (ORDERBOOK.md §16): the same verbs,
   * routed across one process per market. Decided once, from `vaultinfo`.
   */
  private shard(): Promise<ShardedVenue | null> {
    if (!this.sharded) {
      const transport: ShardedTransport = {
        read: <T,>(process: string, key: string) =>
          createAoClient({ node: this.node, process }).readJSON<T>(key),
        send: <T,>(process: string, tags: Array<{ name: string; value: string }>,
          options?: { requiredOutbox?: boolean }) => this.send<T>(process, tags, options),
      };
      this.sharded = isVault(transport, this.process)
        .then((vault) => (vault ? new ShardedVenue(transport, this.process) : null));
    }
    return this.sharded;
  }

  private async signer(): Promise<string> {
    const address = await this.address();
    if (!address || !PROCESS_ID.test(address)) throw new Error('Connect a wallet first.');
    return address;
  }

  private async read<T>(key: string): Promise<T> {
    const value = await this.ao.readJSON<T>(key);
    if (value === null) throw new Error(`Orderbook key ${key} is absent.`);
    return value;
  }

  private async pairViews<T>(
    field: 'book' | 'candles' | 'tape', legacy: string,
  ): Promise<Record<string, T>> {
    let index: Record<string, VenuePairPublication>;
    try { index = await this.read<Record<string, VenuePairPublication>>('venuepairs'); }
    catch { return this.read<Record<string, T>>(legacy); }
    const out: Record<string, T> = {};
    await Promise.all(Object.entries(index).map(async ([id, pair]) => {
      if (!pair || typeof pair[field] !== 'string') return;
      try { out[id] = await this.read<T>(pair[field]); }
      catch { /* A newly configured pair has no projection until its first write. */ }
    }));
    return out;
  }

  async info(): Promise<VenueInfo> {
    const s = await this.shard();
    return s ? s.info() : this.read<VenueInfo>('venueinfo');
  }
  async book(): Promise<VenueBook> {
    const s = await this.shard();
    return s ? s.book<VenueMarketBook>() : this.pairViews<VenueMarketBook>('book', 'venuebook');
  }
  async tape(): Promise<VenueTape> {
    const s = await this.shard();
    return s ? s.tape<VenueTrade[]>() : this.pairViews<VenueTrade[]>('tape', 'venuetape');
  }
  async candles(): Promise<VenueCandles> {
    const s = await this.shard();
    return s ? s.candles<VenueCandles[string]>()
      : this.pairViews<VenueCandles[string]>('candles', 'venuecandles');
  }
  async markets(): Promise<Record<string, VenueMarketConfig>> {
    const s = await this.shard();
    return s ? s.markets() : this.read<Record<string, VenueMarketConfig>>('markets');
  }
  async supply(): Promise<Record<string, VenueSupplyRow>> {
    const s = await this.shard();
    return s ? s.supply() : this.read<Record<string, VenueSupplyRow>>('supply');
  }

  async position(address: string): Promise<VenuePosition> {
    if (!PROCESS_ID.test(address)) return { account: address, free: {}, orders: [], fills: [] };
    const s = await this.shard();
    if (s) return s.position(address);
    const value = await this.ao.readJSON<VenuePosition | Record<string, string>>(`balance-${address}`);
    if (value && 'free' in value) {
      const row = value as VenuePosition;
      return { account: row.account || address, free: row.free ?? {},
        orders: row.orders ?? [], fills: row.fills ?? [] };
    }
    return { account: address, free: (value as Record<string, string> | null) ?? {},
      orders: [], fills: [] };
  }

  private async write<T>(values: Record<string, string>, requiredOutbox = false): Promise<T> {
    return unwrap(await this.send<T & { error?: unknown }>(
      this.process, messageTags(values), { requiredOutbox },
    ));
  }

  async place(side: VenueSide, item: string, price: string | number,
        quantity: string | number, options: OrderOptions = {}) {
    const s = await this.shard();
    if (s) {
      return s.place<{ account: VenuePosition; order: unknown }>(
        await this.signer(), side, item, price, quantity, options);
    }
    return this.write<{ account: VenuePosition; order: unknown }>({
      Action: 'Order.Place', Side: side, Item: item, Price: String(price),
      Quantity: String(quantity), ActionId: actionId('order'),
      ...(options.tif ? { Tif: options.tif } : {}),
      ...(options.stp ? { Stp: options.stp } : {}),
      ...(options.expiresIn ? { ExpiresIn: String(Math.floor(options.expiresIn)) } : {}),
    });
  }
  async amend(orderId: string, changes: { price?: string | number; quantity?: string | number }) {
    const s = await this.shard();
    if (s) {
      return s.amend<{ account: VenuePosition; order: unknown }>(
        orderId, changes, {}, await this.signer());
    }
    return this.write<{ account: VenuePosition; order: unknown }>({
      Action: 'Order.Amend', OrderId: orderId, ActionId: actionId('amend'),
      ...(changes.price !== undefined ? { Price: String(changes.price) } : {}),
      ...(changes.quantity !== undefined ? { Quantity: String(changes.quantity) } : {}),
    });
  }
  async cancel(orderId: string) {
    const s = await this.shard();
    if (s) return s.cancel<{ account: VenuePosition }>(orderId, await this.signer());
    return this.write<{ account: VenuePosition }>({
      Action: 'Order.Cancel', OrderId: orderId, ActionId: actionId('cancel'),
    });
  }
  async cancelAll(item?: string) {
    const s = await this.shard();
    if (s) {
      return s.cancelAll<{ account: VenuePosition }>(await this.signer(), item);
    }
    return this.write<{ account: VenuePosition }>({
      Action: 'Order.CancelAll', ActionId: actionId('cancel-all'), ...(item ? { Item: item } : {}),
    });
  }
  async withdraw(asset: string, quantity: string | number) {
    const s = await this.shard();
    if (s) {
      return s.withdraw<{ account: VenuePosition; withdrawal: unknown }>(
        await this.signer(), asset, quantity);
    }
    return this.write<{ account: VenuePosition; withdrawal: unknown }>({
      Action: 'Withdraw', Asset: asset, Quantity: String(quantity),
    }, true);
  }

  async tokenBalance(tokenProcess: string, address: string): Promise<string> {
    if (!PROCESS_ID.test(tokenProcess) || !PROCESS_ID.test(address)) return '0';
    const token = createAoClient({ node: this.node, process: tokenProcess });
    const direct = await token.readState(`balance-${address}`);
    if (direct !== null && /^\d+$/.test(direct)) return direct;
    return (await token.readJSON<Record<string, string>>('balances'))?.[address] ?? '0';
  }
  depositToken(tokenProcess: string, quantity: string | number) {
    return this.send<{ Balance?: string; Reference?: string }>(
      tokenProcess,
      messageTags({ Action: 'Transfer', Recipient: this.process, Quantity: String(quantity) }),
      { requiredOutbox: true },
    );
  }
}

export const createVenueClient = (configuration: VenueClientConfiguration) => new VenueClient(configuration);

export function parseUnits(text: string, denomination: number): bigint {
  const value = text.trim();
  if (!/^\d+(?:\.\d+)?$/.test(value)) throw new Error('Enter a positive number.');
  const [whole, fraction = ''] = value.split('.');
  if (fraction.length > denomination) throw new Error(`Use at most ${denomination} decimal places.`);
  const atoms = BigInt(whole) * (10n ** BigInt(denomination))
    + BigInt((fraction + '0'.repeat(denomination)).slice(0, denomination) || '0');
  if (atoms <= 0n) throw new Error('Amount must be positive.');
  return atoms;
}

export function formatUnits(value: string | bigint | number, denomination: number,
                            maximumFractionDigits = 6): string {
  const atoms = BigInt(String(value));
  if (!denomination) return atoms.toLocaleString('en-US');
  const scale = 10n ** BigInt(denomination);
  const whole = atoms / scale;
  const fraction = (atoms % scale).toString().padStart(denomination, '0')
    .slice(0, maximumFractionDigits).replace(/0+$/, '');
  return `${whole.toLocaleString('en-US')}${fraction ? `.${fraction}` : ''}`;
}
