export type VenueSide = 'buy' | 'sell';

export interface VenueLevel {
  price: number;
  quantity: number;
  orders: number;
}

export interface VenueMarketBook {
  id: string;
  base: string;
  quote: string;
  status: string;
  tick: number;
  lot: number;
  bestBid?: number;
  bestAsk?: number;
  depth: { bids: VenueLevel[]; asks: VenueLevel[] };
  band?: { low: number; high: number; bps: number };
}

export type VenueBook = Record<string, VenueMarketBook>;
export type VenueTrade = [at: number, price: number, quantity: number, takerBought: number];
export type VenueTape = Record<string, VenueTrade[]>;

export interface VenueInfo {
  Name: string;
  Mode: 'internal' | 'external' | '';
  Sealed: boolean;
  GameProcess?: string;
  Paused: boolean;
  WithdrawalsOpen: boolean;
  Assets: Record<string, { id: string; name: string; kind: string; process?: string }>;
  Markets: Record<string, { id: string; base: string; quote: string; status: string }>;
}

export interface VenueClient {
  info(): Promise<VenueInfo>;
  book(): Promise<VenueBook>;
  tape(): Promise<VenueTape>;
}

const PROCESS_ID = /^[A-Za-z0-9_-]{43}$/;
const KEY = /^[a-z][a-z0-9]*$/;

export function createVenueClient({ node, process }: { node: string; process: string }): VenueClient {
  const base = node.replace(/\/+$/, '');
  if (!/^https?:\/\//.test(base)) throw new Error('Orderbook node must be an HTTP(S) URL.');
  if (!PROCESS_ID.test(process)) throw new Error('Orderbook process must be a 43-character id.');

  const read = async <T>(key: string): Promise<T> => {
    if (!KEY.test(key)) throw new Error(`Unsafe published key: ${key}`);
    const response = await fetch(`${base}/${process}~process@1.0/now/${key}`, {
      headers: { accept: 'application/json, text/plain' },
    });
    const body = (await response.text()).trim();
    if (!response.ok) throw new Error(`Orderbook read failed (${response.status}): ${body.slice(0, 160)}`);
    if (!body || /^<!doctype html|^<html/i.test(body)) throw new Error(`Orderbook key ${key} is absent.`);
    try {
      return JSON.parse(body) as T;
    } catch {
      throw new Error(`Orderbook key ${key} did not return JSON.`);
    }
  };

  return {
    info: () => read<VenueInfo>('venueinfo'),
    book: () => read<VenueBook>('venuebook'),
    tape: () => read<VenueTape>('venuetape'),
  };
}
