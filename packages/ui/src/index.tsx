import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  connectWallet, createVenueClient, formatUnits, parseUnits, restoreWallet,
  type VenueAsset, type VenueBook, type VenueCandles, type VenueInfo,
  type VenueMarketBook, type VenueMarketConfig, type VenuePosition, type VenueTape,
  type VenueTif, type WalletProviderId,
} from '../../client/src/index';

export interface OrderbookHost {
  account?: string | null;
  connect?: () => Promise<string | null>;
  execute?: (action: () => Promise<unknown>, success: string) => Promise<unknown>;
  outsideBalances?: Record<string, string | number>;
  deposit?: (asset: VenueAsset, backingAmount: bigint) => Promise<unknown>;
}

export interface OrderbookTerminalProps {
  node: string;
  process: string;
  embedded?: boolean;
  host?: OrderbookHost;
}

const n = (value: unknown) => Number(value ?? 0) || 0;
const denomination = (asset?: VenueAsset) => Math.max(0, Math.min(18, n(asset?.denomination)));
const label = (asset?: VenueAsset) => asset?.ticker || asset?.name || asset?.id || 'asset';
const short = (address: string) => `${address.slice(0, 5)}…${address.slice(-4)}`;

function depthTotal(rows: Array<{ quantity: number }>) {
  return rows.reduce((sum, row) => sum + n(row.quantity), 0);
}

function PriceChart({ market, tape, candles, format }: {
  market: VenueMarketBook; tape: VenueTape | null; candles: VenueCandles | null;
  format: (price: number) => string;
}) {
  const points = useMemo(() => {
    const trades = (tape?.[market.id] ?? []).map(([at, price]) => ({ t: at, price }));
    if (trades.length) return trades.slice(-96);
    return (candles?.[market.id]?.['300'] ?? []).map((row) => ({ t: row[0], price: row[4] }));
  }, [candles, market.id, tape]);
  if (!points.length) return <div className="ob-chart-empty">The first fill will draw this market.</div>;
  const width = 800; const height = 260; const pad = 24;
  const low = Math.min(...points.map((row) => row.price));
  const high = Math.max(...points.map((row) => row.price));
  const spread = Math.max(1, high - low);
  const path = points.map((row, index) => {
    const x = pad + (index / Math.max(1, points.length - 1)) * (width - pad * 2);
    const y = height - pad - ((row.price - low) / spread) * (height - pad * 2);
    return `${index ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');
  return (
    <div className="ob-chart">
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Recent execution price">
        <defs><linearGradient id="ob-fill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="var(--ob-signal)" stopOpacity=".28" />
          <stop offset="1" stopColor="var(--ob-signal)" stopOpacity="0" />
        </linearGradient></defs>
        <path className="ob-chart-area" d={`${path} L${width - pad},${height - pad} L${pad},${height - pad} Z`} />
        <path className="ob-chart-line" d={path} />
      </svg>
      <span className="ob-chart-high">{format(high)}</span>
      <span className="ob-chart-low">{format(low)}</span>
    </div>
  );
}

function Depth({ market, format, onPrice }: {
  market: VenueMarketBook; format: (value: number) => string; onPrice: (value: number) => void;
}) {
  const asks = [...(market.depth?.asks ?? [])].slice(0, 8).reverse();
  const bids = [...(market.depth?.bids ?? [])].slice(0, 8);
  const maximum = Math.max(1, ...asks.concat(bids).map((row) => n(row.quantity)));
  const rows = (side: 'ask' | 'bid', values: typeof asks) => values.map((row) => (
    <button key={`${side}-${row.price}`} className={`ob-depth-row ${side}`} onClick={() => onPrice(row.price)}>
      <span className="ob-depth-fill" style={{ width: `${Math.max(4, n(row.quantity) / maximum * 100)}%` }} />
      <b>{format(row.price)}</b><span>{row.quantity.toLocaleString()}</span><small>{row.orders}</small>
    </button>
  ));
  return <div className="ob-depth" aria-label="Orderbook depth">
    <header><span>Price</span><span>Lots</span><span>Orders</span></header>
    {rows('ask', asks)}
    <div className="ob-spread"><span>spread</span><b>{market.bestBid && market.bestAsk
      ? format(market.bestAsk - market.bestBid) : '—'}</b></div>
    {rows('bid', bids)}
  </div>;
}

export function MarketOverview({ info, book }: { info: VenueInfo | null; book: VenueBook | null }) {
  const markets = Object.values(book ?? {}).sort((a, b) => a.id.localeCompare(b.id));
  return <section className="ob-overview" aria-label="Live markets">
    <header><div><span className="ob-eyebrow">Live venue</span><h2>{info?.Name ?? 'Orderbook'}</h2></div>
      <span className={`ob-status ${info?.Paused ? 'paused' : ''}`}>{info?.Paused ? 'Paused' : info ? 'Open' : 'Connecting'}</span></header>
    {markets.map((market) => <article key={market.id}><strong>{market.base} / {market.quote}</strong>
      <span>bid {market.bestBid ?? '—'}</span><span>ask {market.bestAsk ?? '—'}</span>
      <span>{[...market.depth.bids, ...market.depth.asks].reduce((sum, row) => sum + row.orders, 0)} orders</span></article>)}
    {!markets.length && <p>No launched markets are published yet.</p>}
  </section>;
}

export function OrderbookTerminal({ node, process, embedded = false, host }: OrderbookTerminalProps) {
  const client = useMemo(() => createVenueClient({ node, process }), [node, process]);
  const [info, setInfo] = useState<VenueInfo | null>(null);
  const [book, setBook] = useState<VenueBook | null>(null);
  const [tape, setTape] = useState<VenueTape | null>(null);
  const [candles, setCandles] = useState<VenueCandles | null>(null);
  const [configs, setConfigs] = useState<Record<string, VenueMarketConfig>>({});
  const [position, setPosition] = useState<VenuePosition | null>(null);
  const [account, setAccount] = useState<string | null>(host?.account ?? null);
  const [outside, setOutside] = useState<Record<string, string | number>>(host?.outsideBalances ?? {});
  const [marketId, setMarketId] = useState('');
  const [side, setSide] = useState<'buy' | 'sell'>('buy');
  const [tif, setTif] = useState<VenueTif>('GTC');
  const [price, setPrice] = useState('');
  const [quantity, setQuantity] = useState('1');
  const [custodyAsset, setCustodyAsset] = useState('');
  const [custodyAmount, setCustodyAmount] = useState('');
  const [walletOpen, setWalletOpen] = useState(false);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  useEffect(() => { setAccount(host?.account ?? null); }, [host?.account]);
  useEffect(() => { setOutside(host?.outsideBalances ?? {}); }, [host?.outsideBalances]);

  const refresh = useCallback(async () => {
    setError('');
    try {
      const [nextInfo, nextBook, nextTape, nextCandles, nextConfigs, nextPosition] = await Promise.all([
        client.info(), client.book(), client.tape().catch(() => ({})),
        client.candles().catch(() => ({})), client.markets(),
        account ? client.position(account) : Promise.resolve(null),
      ]);
      setInfo(nextInfo); setBook(nextBook); setTape(nextTape); setCandles(nextCandles);
      setConfigs(nextConfigs); setPosition(nextPosition);
      if (!marketId || !nextBook[marketId]) setMarketId(Object.keys(nextBook)[0] ?? '');
      if (account && !host?.outsideBalances) {
        const pairs = await Promise.all(Object.values(nextInfo.Assets).map(async (asset) => [
          asset.id, asset.process ? await client.tokenBalance(asset.process, account) : '0',
        ] as const));
        setOutside(Object.fromEntries(pairs));
      }
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
  }, [account, client, host?.outsideBalances, marketId]);

  useEffect(() => { void refresh(); const id = window.setInterval(() => void refresh(), 10_000); return () => window.clearInterval(id); }, [refresh]);
  useEffect(() => {
    if (host?.account !== undefined) return;
    void restoreWallet().then((wallet) => wallet && setAccount(wallet.address)).catch(() => undefined);
  }, [host?.account]);

  const markets = Object.values(book ?? {}).filter((row) => row.status !== 'delisted');
  const market = markets.find((row) => row.id === marketId) ?? markets[0];
  const base = info?.Assets?.[market?.base ?? '']; const quote = info?.Assets?.[market?.quote ?? ''];
  const priceDenom = denomination(quote);
  const formatPrice = (value: number) => formatUnits(BigInt(Math.round(value)), priceDenom, Math.max(2, Math.min(8, priceDenom)));
  const config = market ? configs[market.id] : undefined;

  const connect = async (provider: WalletProviderId) => {
    setBusy('connect'); setError('');
    try {
      const address = host?.connect ? await host.connect() : (await connectWallet(provider)).address;
      if (address) { setAccount(address); setWalletOpen(false); setNotice(`Connected ${short(address)}`); }
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
    finally { setBusy(''); }
  };
  const execute = async (key: string, success: string, action: () => Promise<unknown>) => {
    if (!account) { setWalletOpen(true); return; }
    setBusy(key); setError(''); setNotice('');
    try {
      if (host?.execute) await host.execute(action, success); else await action();
      setNotice(success); await new Promise((resolve) => window.setTimeout(resolve, 700)); await refresh();
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
    finally { setBusy(''); }
  };
  const submit = () => {
    if (!market || !quote) return;
    try {
      const rawPrice = parseUnits(price, priceDenom);
      const lots = Number(quantity);
      if (!Number.isSafeInteger(lots) || lots <= 0) throw new Error('Lots must be a positive whole number.');
      if (rawPrice > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Price is too large.');
      void execute('order', 'Order submitted.', () => client.place(side, market.base, rawPrice.toString(), lots, { tif }));
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
  };
  const selectedAsset = info?.Assets?.[custodyAsset || (side === 'buy' ? market?.quote ?? '' : market?.base ?? '')];
  const moveCustody = (direction: 'deposit' | 'withdraw') => {
    if (!selectedAsset) return;
    try {
      const backingDenom = selectedAsset.kind === 'game' ? 0 : denomination(selectedAsset);
      const backing = parseUnits(custodyAmount, backingDenom);
      const scale = 10n ** BigInt(denomination(selectedAsset));
      const venueAmount = selectedAsset.kind === 'game' ? backing * scale : backing;
      const action = direction === 'withdraw'
        ? () => client.withdraw(selectedAsset.id, venueAmount.toString())
        : host?.deposit
          ? () => host.deposit!(selectedAsset, backing)
          : selectedAsset.process
            ? () => client.depositToken(selectedAsset.process!, backing.toString())
            : () => Promise.reject(new Error('This game asset needs a host custody adapter.'));
      void execute(`custody-${direction}`, `${label(selectedAsset)} ${direction} submitted.`, action);
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
  };

  return <section className={`ob-terminal ${embedded ? 'embedded' : ''}`}>
    <header className="ob-terminal-head"><div><span className="ob-eyebrow">Public limit markets</span>
      <h2>{info?.Name ?? 'Orderbook'}</h2></div><div className="ob-head-actions">
      <span className={`ob-status ${info?.Paused ? 'paused' : ''}`}>{info?.Paused ? 'Paused' : 'Open'}</span>
      <button onClick={() => account ? setWalletOpen(true) : setWalletOpen(true)}>{account ? short(account) : 'Connect'}</button>
    </div></header>
    {walletOpen && <div className="ob-wallet" role="dialog" aria-label="Connect wallet">
      <b>Choose a signer</b><button onClick={() => void connect('injected')} disabled={!!busy}>Wander / extension</button>
      <button onClick={() => void connect('permaweb')} disabled={!!busy}>PermawebOS</button>
      <button onClick={() => void connect('local')} disabled={!!busy}>Browser wallet</button>
      <button className="quiet" onClick={() => setWalletOpen(false)}>Close</button></div>}
    {error && <p className="ob-alert error" role="alert">{error}</p>}{notice && <p className="ob-alert success">{notice}</p>}
    <div className="ob-market-tabs">{markets.map((row) => <button key={row.id} className={row.id === market?.id ? 'active' : ''}
      onClick={() => setMarketId(row.id)}><b>{label(info?.Assets[row.base])}</b><span>/ {label(info?.Assets[row.quote])}</span></button>)}</div>
    {market ? <div className="ob-workspace">
      <div className="ob-chart-panel"><div className="ob-ticker"><div><span>Last</span><b>{(tape?.[market.id] ?? []).length
        ? formatPrice((tape?.[market.id] ?? []).at(-1)![1]) : '—'}</b></div><div><span>Bid</span><b>{market.bestBid ? formatPrice(market.bestBid) : '—'}</b></div>
        <div><span>Ask</span><b>{market.bestAsk ? formatPrice(market.bestAsk) : '—'}</b></div>
        <div><span>Base depth</span><b>{(depthTotal(market.depth.bids) + depthTotal(market.depth.asks)).toLocaleString()}</b></div></div>
        <PriceChart market={market} tape={tape} candles={candles} format={formatPrice} />
        <div className="ob-trades"><header><b>Recent trades</b><span>Price</span><span>Lots</span></header>
          {(tape?.[market.id] ?? []).slice(-8).reverse().map(([at, tradePrice, lots, bought], index) => <div key={`${at}-${index}`}>
            <time>{new Date(at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time>
            <b className={bought ? 'buy' : 'sell'}>{formatPrice(tradePrice)}</b><span>{lots}</span></div>)}
          {!(tape?.[market.id]?.length) && <p>No executions yet.</p>}</div>
      </div>
      <Depth market={market} format={formatPrice} onPrice={(value) => setPrice(formatUnits(value, priceDenom, priceDenom))} />
      <aside className="ob-ticket"><div className="ob-side"><button className={side === 'buy' ? 'active buy' : ''} onClick={() => setSide('buy')}>Buy</button>
        <button className={side === 'sell' ? 'active sell' : ''} onClick={() => setSide('sell')}>Sell</button></div>
        <label>Order type<select value={tif} onChange={(event) => setTif(event.target.value as VenueTif)}>
          <option value="GTC">Limit</option><option value="IOC">Immediate or cancel</option><option value="FOK">Fill all now</option><option value="PostOnly">Maker only</option>
        </select></label><label>Price · {label(quote)}<input inputMode="decimal" value={price} placeholder="0.00" onChange={(event) => setPrice(event.target.value)} /></label>
        <label>Quantity · lots<input inputMode="numeric" value={quantity} onChange={(event) => setQuantity(event.target.value)} /></label>
        <div className="ob-ticket-meta"><span>Tick {config ? formatPrice(config.tick) : '—'}</span><span>Taker {config ? `${config.takerBps / 100}%` : '—'}</span></div>
        <button className={`ob-submit ${side}`} disabled={!!busy || info?.Paused} onClick={submit}>{busy === 'order' ? 'Settling…' : `${side === 'buy' ? 'Buy' : 'Sell'} ${label(base)}`}</button>
        {market.band && <small>Accepted prices: {formatPrice(market.band.low)}–{formatPrice(market.band.high)} {label(quote)}</small>}
      </aside>
    </div> : <div className="ob-empty">No launched market is available.</div>}
    {market && <div className="ob-account-grid"><section><header><b>Custody</b><span>Venue / outside</span></header>
      <div className="ob-custody-assets">{[market.quote, market.base].map((id) => { const asset = info?.Assets[id]; const inside = position?.free?.[id] ?? '0';
        const insideDenom = denomination(asset); const outsideDenom = asset?.kind === 'game' ? 0 : insideDenom; return <button key={id} className={(selectedAsset?.id === id) ? 'active' : ''} onClick={() => setCustodyAsset(id)}>
          <b>{label(asset)}</b><span>{formatUnits(inside, insideDenom, 6)} / {formatUnits(String(outside[id] ?? 0), outsideDenom, 6)}</span></button>; })}</div>
      <div className="ob-custody-form"><input inputMode="decimal" placeholder="Amount" value={custodyAmount} onChange={(event) => setCustodyAmount(event.target.value)} />
        <button onClick={() => moveCustody('deposit')} disabled={!!busy}>Deposit</button><button onClick={() => moveCustody('withdraw')} disabled={!!busy}>Withdraw</button></div></section>
      <section><header><b>Open orders</b><button className="quiet" onClick={() => void execute('cancel-all', 'Orders cancelled.', () => client.cancelAll(market.base))}>Cancel all</button></header>
        <div className="ob-orders">{(position?.orders ?? []).filter((row) => row.market === market.id).map((order) => <div key={order.id}>
          <span className={order.side}>{order.side}</span><b>{order.remaining} @ {formatPrice(order.price)}</b>
          <button onClick={() => void execute(`cancel-${order.id}`, 'Order cancelled.', () => client.cancel(order.id))}>Cancel</button></div>)}
          {!position?.orders?.some((row) => row.market === market.id) && <p>No open orders.</p>}</div></section></div>}
  </section>;
}
