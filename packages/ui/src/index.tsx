import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  connectWallet, createVenueClient, formatUnits, parseUnits, restoreWallet,
  type VenueAsset, type VenueBook, type VenueCandles, type VenueFill, type VenueInfo,
  type VenueMarketBook, type VenueMarketConfig, type VenueOrder, type VenuePosition,
  type VenueSend, type VenueTape, type VenueTif, type WalletProviderId,
} from '../../client/src/index';

export interface OrderbookHost {
  account?: string | null;
  connect?: () => Promise<string | null>;
  execute?: (action: () => Promise<unknown>, success: string) => Promise<unknown>;
  send?: VenueSend;
  outsideBalances?: Record<string, string | number>;
  deposit?: (asset: VenueAsset, backingAmount: bigint) => Promise<unknown>;
}

export interface OrderbookTerminalProps {
  node: string;
  process: string;
  embedded?: boolean;
  host?: OrderbookHost;
  initialMarket?: string;
  initialSide?: 'buy' | 'sell';
  initialPrice?: string;
  initialQuantity?: string;
}

type ChartMode = 'line' | 'candles';
type ChartRange = '30m' | '1h' | '3h' | '12h' | '24h';
type Bar = { t: number; open: number; high: number; low: number; close: number; volume: number };

const RANGES: ChartRange[] = ['30m', '1h', '3h', '12h', '24h'];
const RANGE_MS: Record<ChartRange, number> = {
  '30m': 1_800_000, '1h': 3_600_000, '3h': 10_800_000, '12h': 43_200_000, '24h': 86_400_000,
};
const TIFS: Array<{ value: VenueTif; label: string; copy: string }> = [
  { value: 'GTC', label: 'Limit', copy: 'Trades at your limit or better; any remainder rests until filled or withdrawn.' },
  { value: 'IOC', label: 'Market', copy: 'Takes what the ladder offers now and cancels the rest.' },
  { value: 'FOK', label: 'Fill all now', copy: 'Fills the whole quantity now or does nothing.' },
  { value: 'PostOnly', label: 'Maker only', copy: 'Refused rather than crossed, so this only adds liquidity.' },
];
const n = (value: unknown) => Number(value ?? 0) || 0;
const denom = (asset?: VenueAsset) => Math.max(0, Math.min(18, n(asset?.denomination)));
const assetLabel = (asset?: VenueAsset) => asset?.ticker || asset?.name || asset?.id || 'asset';
const short = (address: string) => `${address.slice(0, 5)}…${address.slice(-4)}`;
const fmtInt = (value: number) => value.toLocaleString('en-US');
const relative = (timestamp: number) => {
  const ms = timestamp < 10_000_000_000 ? timestamp * 1000 : timestamp;
  const seconds = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (seconds < 60) return 'now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
};

function PriceChart({ market, tape, candles, mode, range, format }: {
  market: VenueMarketBook; tape: VenueTape | null; candles: VenueCandles | null;
  mode: ChartMode; range: ChartRange; format: (price: number) => string;
}) {
  const from = Date.now() - RANGE_MS[range];
  const trades = (tape?.[market.id] ?? []).filter(([at]) => at * 1000 >= from);
  const bars: Bar[] = (candles?.[market.id]?.['300'] ?? []).filter(([at]) => at * 1000 >= from)
    .map(([t, open, high, low, close, volume]) => ({ t, open, high, low, close, volume }));
  const points = trades.length
    ? trades.map(([t, price, volume]) => ({ t, price, volume }))
    : bars.map((bar) => ({ t: bar.t, price: bar.close, volume: bar.volume }));
  const prices = mode === 'candles' && bars.length
    ? bars.flatMap((bar) => [bar.high, bar.low]) : points.map((point) => point.price);
  if (!prices.length) return <div className="ob-chart-empty">No trades fall inside this window.</div>;
  const width = 900; const height = 420; const plotBottom = 315; const left = 20; const right = 42;
  const low = Math.min(...prices); const high = Math.max(...prices); const spread = Math.max(1, high - low);
  const rows = mode === 'candles' && bars.length ? bars : points;
  const x = (index: number) => left + (index / Math.max(1, rows.length - 1)) * (width - left - right);
  const y = (value: number) => 18 + ((high - value) / spread) * (plotBottom - 38);
  const maxVolume = Math.max(1, ...rows.map((row) => row.volume));
  const path = points.map((point, index) => `${index ? 'L' : 'M'}${x(index).toFixed(1)},${y(point.price).toFixed(1)}`).join(' ');
  return <div className="ob-chart"><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Price and volume">
    {[0, 1, 2, 3, 4].map((step) => <line key={step} className="ob-grid" x1="0" x2={width} y1={18 + step * 70} y2={18 + step * 70} />)}
    {mode === 'line' || !bars.length ? <><path className="ob-line-fill" d={`${path} L${x(points.length - 1)},${plotBottom} L${left},${plotBottom} Z`} /><path className="ob-line" d={path} /></>
      : bars.map((bar, index) => { const cx = x(index); const up = bar.close >= bar.open; const cw = Math.max(3, Math.min(13, 480 / bars.length)); return <g key={`${bar.t}-${index}`} className={up ? 'ob-up' : 'ob-down'}><line x1={cx} x2={cx} y1={y(bar.high)} y2={y(bar.low)} /><rect x={cx - cw / 2} y={Math.min(y(bar.open), y(bar.close))} width={cw} height={Math.max(2, Math.abs(y(bar.open) - y(bar.close)))} /></g>; })}
    {rows.map((row, index) => { const h = row.volume / maxVolume * 78; return <rect key={`v-${index}`} className="ob-volume" x={x(index) - 3} y={height - h - 16} width="6" height={h} />; })}
  </svg><span className="ob-chart-high">{format(high)}</span><span className="ob-chart-low">{format(low)}</span></div>;
}

function DepthMountain({ market, format }: { market: VenueMarketBook; format: (price: number) => string }) {
  const accumulate = (source: typeof market.depth.bids, descending: boolean) => {
    let total = 0;
    return [...source].sort((a, b) => descending ? b.price - a.price : a.price - b.price)
      .slice(0, 10).map((row) => ({ ...row, total: (total += row.quantity) }));
  };
  const bids = accumulate(market.depth.bids, true).reverse(); const asks = accumulate(market.depth.asks, false);
  const max = Math.max(1, ...bids.map((row) => row.total), ...asks.map((row) => row.total));
  const bidPath = bids.map((row, index) => `${index ? 'L' : 'M'}${248 - index * 20},${137 - row.total / max * 103}`).join(' ');
  const askPath = asks.map((row, index) => `${index ? 'L' : 'M'}${272 + index * 20},${137 - row.total / max * 103}`).join(' ');
  return <div className="ob-depth-mountain"><div className="ob-depth-caption"><span>{bids.at(-1)?.total ?? 0} bid units</span><span>Cumulative depth</span><span>{asks.at(-1)?.total ?? 0} ask units</span></div>
    <svg viewBox="0 0 520 155" aria-label="Cumulative depth"><line className="ob-depth-mid" x1="260" x2="260" y1="22" y2="140" />
      {bidPath && <><path className="ob-bid-area" d={`${bidPath} L248,140 L48,140 Z`} /><path className="ob-bid-line" d={bidPath} /></>}
      {askPath && <><path className="ob-ask-area" d={`${askPath} L472,140 L272,140 Z`} /><path className="ob-ask-line" d={askPath} /></>}</svg>
    <div className="ob-depth-axis"><span>{bids[0] ? format(bids[0].price) : '—'}</span><span>MID</span><span>{asks.at(-1) ? format(asks.at(-1)!.price) : '—'}</span></div></div>;
}

function DepthList({ title, side, rows, format, onPick }: {
  title: string; side: 'bid' | 'ask'; rows: VenueMarketBook['depth']['bids'];
  format: (price: number) => string; onPick: (price: number) => void;
}) {
  const max = Math.max(1, ...rows.map((row) => row.quantity));
  return <div className="ob-depth-list"><header>{title}</header>{rows.slice(0, 10).map((row) => <button type="button" key={`${side}-${row.price}`} className={side} onClick={() => onPick(row.price)}>
    <span className="ob-level-fill" style={{ width: `${Math.max(4, row.quantity / max * 100)}%` }} /><b>{format(row.price)}</b><span>× {fmtInt(row.quantity)}</span></button>)}{!rows.length && <p>No depth</p>}</div>;
}

export function MarketOverview({ info, book }: { info: VenueInfo | null; book: VenueBook | null }) {
  const markets = Object.values(book ?? {}).sort((a, b) => a.id.localeCompare(b.id));
  return <section className="ob-overview" aria-label="Live markets"><header><div><span className="ob-eyebrow">Live venue</span><h2>{info?.Name ?? 'Orderbook'}</h2></div><span className={`ob-status ${info?.Paused ? 'paused' : ''}`}>{info?.Paused ? 'Paused' : info ? 'Open' : 'Connecting'}</span></header>
    {markets.map((market) => <article key={market.id}><strong>{market.base} / {market.quote}</strong><span>bid {market.bestBid ?? '—'}</span><span>ask {market.bestAsk ?? '—'}</span><span>{market.depth.bids.length + market.depth.asks.length} levels</span></article>)}{!markets.length && <p>No launched markets are published yet.</p>}</section>;
}

export function OrderbookTerminal({ node, process, embedded = false, host, initialMarket = '', initialSide = 'buy', initialPrice = '', initialQuantity = '1' }: OrderbookTerminalProps) {
  const client = useMemo(() => createVenueClient({ node, process, send: host?.send }), [host?.send, node, process]);
  const [info, setInfo] = useState<VenueInfo | null>(null); const [book, setBook] = useState<VenueBook | null>(null);
  const [tape, setTape] = useState<VenueTape | null>(null); const [candles, setCandles] = useState<VenueCandles | null>(null);
  const [configs, setConfigs] = useState<Record<string, VenueMarketConfig>>({}); const [position, setPosition] = useState<VenuePosition | null>(null);
  const [account, setAccount] = useState<string | null>(host?.account ?? null); const [outside, setOutside] = useState<Record<string, string | number>>(host?.outsideBalances ?? {});
  const [marketId, setMarketId] = useState(initialMarket); const [side, setSide] = useState<'buy' | 'sell'>(initialSide); const [tif, setTif] = useState<VenueTif>('GTC');
  const [price, setPrice] = useState(initialPrice); const [quantity, setQuantity] = useState(initialQuantity); const [custodyAsset, setCustodyAsset] = useState(''); const [custodyAmount, setCustodyAmount] = useState('');
  const [chartMode, setChartMode] = useState<ChartMode>('candles'); const [chartRange, setChartRange] = useState<ChartRange>('3h');
  const [walletOpen, setWalletOpen] = useState(false); const [busy, setBusy] = useState(''); const [error, setError] = useState(''); const [notice, setNotice] = useState('');

  useEffect(() => { setAccount(host?.account ?? null); if (host?.account) setWalletOpen(false); }, [host?.account]);
  useEffect(() => setOutside(host?.outsideBalances ?? {}), [host?.outsideBalances]);
  useEffect(() => { if (initialMarket) setMarketId(initialMarket); setSide(initialSide); if (initialPrice) setPrice(initialPrice); if (initialQuantity) setQuantity(initialQuantity); }, [initialMarket, initialPrice, initialQuantity, initialSide]);
  const refresh = useCallback(async () => { setError(''); try {
    const [nextInfo, nextBook, nextTape, nextCandles, nextConfigs, nextPosition] = await Promise.all([client.info(), client.book(), client.tape().catch(() => ({})), client.candles().catch(() => ({})), client.markets(), account ? client.position(account) : Promise.resolve(null)]);
    setInfo(nextInfo); setBook(nextBook); setTape(nextTape); setCandles(nextCandles); setConfigs(nextConfigs); setPosition(nextPosition);
    if (!marketId || !nextBook[marketId]) setMarketId(Object.keys(nextBook)[0] ?? '');
    if (account && !host?.outsideBalances) { const balances = await Promise.all(Object.values(nextInfo.Assets).map(async (asset) => [asset.id, asset.process ? await client.tokenBalance(asset.process, account) : '0'] as const)); setOutside(Object.fromEntries(balances)); }
  } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); } }, [account, client, host?.outsideBalances, marketId]);
  useEffect(() => { void refresh(); const id = window.setInterval(() => void refresh(), 10_000); return () => window.clearInterval(id); }, [refresh]);
  useEffect(() => { if (host?.account !== undefined) return; void restoreWallet().then((wallet) => wallet && setAccount(wallet.address)).catch(() => undefined); }, [host?.account]);

  const markets = Object.values(book ?? {}).filter((row) => row.status !== 'delisted'); const market = markets.find((row) => row.id === marketId) ?? markets[0];
  const base = info?.Assets?.[market?.base ?? '']; const quote = info?.Assets?.[market?.quote ?? '']; const priceDenom = denom(quote);
  const formatPrice = (value: number) => formatUnits(BigInt(Math.round(value)), priceDenom, Math.max(2, Math.min(8, priceDenom)));
  const config = market ? configs[market.id] : undefined; const marketTape = market ? tape?.[market.id] ?? [] : [];
  const completedTrades = (market?.candles ?? []).reduce((sum, row) => sum + n(row.n), 0); const tradedVolume = (market?.candles ?? []).reduce((sum, row) => sum + n(row.v), 0);
  const orders = (position?.orders ?? []).filter((row) => row.market === market?.id); const fills = (position?.fills ?? []).filter((row) => row.market === market?.id).slice(0, 10);
  const execute = async (key: string, success: string, action: () => Promise<unknown>) => { if (!account) { setWalletOpen(true); return; } setBusy(key); setError(''); setNotice(''); try { if (host?.execute) await host.execute(action, success); else await action(); setNotice(success); await new Promise((resolve) => window.setTimeout(resolve, 700)); await refresh(); } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); } finally { setBusy(''); } };
  const connect = async (provider: WalletProviderId) => { setBusy('connect'); setError(''); try { const address = host?.connect ? await host.connect() : (await connectWallet(provider)).address; if (address) { setAccount(address); setWalletOpen(false); setNotice(`Connected ${short(address)}`); } } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); } finally { setBusy(''); } };

  const lots = Math.floor(Number(quantity)); const immediate = tif === 'IOC' || tif === 'FOK';
  const sweep = (() => { if (!market || lots <= 0) return { price: 0, available: 0 }; let available = 0; let limit = 0; for (const row of side === 'buy' ? market.depth.asks : market.depth.bids) { available += row.quantity; limit = row.price; if (available >= lots) break; } return { price: limit, available }; })();
  let parsedPrice = 0; let priceError = ''; try { parsedPrice = immediate ? sweep.price : Number(parseUnits(price, priceDenom)); } catch (reason) { if (price) priceError = reason instanceof Error ? reason.message : String(reason); }
  const notional = parsedPrice > 0 && lots > 0 ? parsedPrice * lots : 0; const crosses = Boolean(market && parsedPrice > 0 && (side === 'buy' ? market.bestAsk && parsedPrice >= market.bestAsk : market.bestBid && parsedPrice <= market.bestBid));
  const fee = crosses && config?.takerBps ? Math.ceil(notional * config.takerBps / 10000) : 0; const outsideBand = Boolean(market?.band && parsedPrice && (parsedPrice < market.band.low || parsedPrice > market.band.high));
  const ready = lots > 0 && parsedPrice > 0 && !priceError && !outsideBand && !(tif === 'PostOnly' && crosses) && !(immediate && !sweep.price) && !(tif === 'FOK' && sweep.available < lots);
  const submit = () => { if (market && ready) void execute('order', 'Order submitted.', () => client.place(side, market.base, parsedPrice, lots, { tif })); };
  const selectedAsset = info?.Assets?.[custodyAsset || (side === 'buy' ? market?.quote ?? '' : market?.base ?? '')];
  const moveCustody = (direction: 'deposit' | 'withdraw') => { if (!selectedAsset) return; try { const backingDenom = selectedAsset.kind === 'game' ? 0 : denom(selectedAsset); const backing = parseUnits(custodyAmount, backingDenom); const venueAmount = selectedAsset.kind === 'game' ? backing * 10n ** BigInt(denom(selectedAsset)) : backing; const action = direction === 'withdraw' ? () => client.withdraw(selectedAsset.id, venueAmount.toString()) : host?.deposit ? () => host.deposit!(selectedAsset, backing) : selectedAsset.process ? () => client.depositToken(selectedAsset.process!, backing.toString()) : () => Promise.reject(new Error('This game asset needs a host custody adapter.')); void execute(`custody-${direction}`, `${assetLabel(selectedAsset)} ${direction} submitted.`, action); } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); } };

  return <section className={`ob-terminal ${embedded ? 'embedded' : ''}`}>{walletOpen && <div className="ob-wallet" role="dialog" aria-label="Connect wallet"><b>Choose a signer</b><button onClick={() => void connect('injected')}>Wander / extension</button><button onClick={() => void connect('permaweb')}>PermawebOS</button><button onClick={() => void connect('local')}>Browser wallet</button><button className="quiet" onClick={() => setWalletOpen(false)}>Close</button></div>}
    {error && <p className="ob-alert error" role="alert">{error}</p>}{notice && <p className="ob-alert success">{notice}</p>}
    <div className="ob-health ob-panel"><label className="ob-pair"><span className="ob-mark">◈</span><select aria-label="Market" value={market?.id ?? ''} onChange={(event) => setMarketId(event.target.value)}>{markets.map((row) => <option key={row.id} value={row.id}>{assetLabel(info?.Assets[row.base])} / {assetLabel(info?.Assets[row.quote])}</option>)}</select><span className="ob-pair-quotes"><i>{market?.bestBid ? formatPrice(market.bestBid) : '—'}</i> / <b>{market?.bestAsk ? formatPrice(market.bestAsk) : '—'}</b></span></label>
      <div className="ob-health-actions">{market && <details className="ob-custody"><summary>⇄ Move assets</summary><div className="ob-custody-popover"><span className="ob-eyebrow">Outside ↔ this venue</span><div className="ob-custody-assets">{[market.quote, market.base].map((id) => { const asset = info?.Assets[id]; return <button key={id} className={selectedAsset?.id === id ? 'active' : ''} onClick={() => setCustodyAsset(id)}><b>{assetLabel(asset)}</b><span>{formatUnits(String(outside[id] ?? 0), asset?.kind === 'game' ? 0 : denom(asset), 6)} → {formatUnits(position?.free?.[id] ?? '0', denom(asset), 6)}</span></button>; })}</div><input inputMode="decimal" placeholder="Amount" value={custodyAmount} onChange={(event) => setCustodyAmount(event.target.value)} /><div className="ob-custody-buttons"><button onClick={() => moveCustody('deposit')}>Deposit</button><button onClick={() => moveCustody('withdraw')}>Withdraw</button></div><p>Cancel orders before withdrawing escrow.</p></div></details>}<button className="quiet" onClick={() => void refresh()}>↻ Refresh</button><span className={`ob-status ${info?.Paused ? 'paused' : ''}`}>{info?.Paused ? 'Paused' : info ? 'Open' : 'Connecting'}</span><button onClick={() => setWalletOpen(true)}>{account ? short(account) : 'Connect'}</button></div>
      <div className="ob-health-stats"><span><i>Completed trades</i><b>{fmtInt(completedTrades)}</b></span><span><i>Traded volume</i><b>{fmtInt(tradedVolume)} {assetLabel(base)}</b></span><span><i>{assetLabel(quote)} here</i><b>{formatUnits(position?.free?.[market?.quote ?? ''] ?? '0', denom(quote), 6)}</b></span><span><i>{assetLabel(base)} here</i><b>{formatUnits(position?.free?.[market?.base ?? ''] ?? '0', denom(base), 6)}</b></span><span><i>Your orders</i><b>{orders.length}</b></span></div></div>
    {market ? <div className="ob-floor"><section className="ob-chart-panel ob-panel"><header className="ob-panel-head"><h3>{assetLabel(base)} <span>/ {assetLabel(quote)}</span></h3><div className="ob-chart-tools"><button className={chartMode === 'line' ? 'active' : ''} onClick={() => setChartMode('line')}>Line</button><button className={chartMode === 'candles' ? 'active' : ''} onClick={() => setChartMode('candles')}>Candles</button>{RANGES.map((value) => <button key={value} className={chartRange === value ? 'active' : ''} onClick={() => setChartRange(value)}>{value}</button>)}</div></header><div className="ob-ticker"><span><i>Last</i><b>{marketTape.length ? formatPrice(marketTape.at(-1)![1]) : '—'}</b></span><span><i>Bid</i><b>{market.bestBid ? formatPrice(market.bestBid) : '—'}</b></span><span><i>Ask</i><b>{market.bestAsk ? formatPrice(market.bestAsk) : '—'}</b></span><span><i>Vol 7d</i><b>{fmtInt(tradedVolume)}</b></span><span><i>Trades 7d</i><b>{fmtInt(completedTrades)}</b></span></div><PriceChart market={market} tape={tape} candles={candles} mode={chartMode} range={chartRange} format={formatPrice} /></section>
      <section className="ob-depth-panel ob-panel"><div className="ob-top-book"><span><i>Best bid</i><b className="buy">{market.bestBid ? formatPrice(market.bestBid) : '—'}</b></span><span><i>Spread</i><b>{market.bestBid && market.bestAsk ? formatPrice(market.bestAsk - market.bestBid) : '—'}</b></span><span><i>Best ask</i><b className="sell">{market.bestAsk ? formatPrice(market.bestAsk) : '—'}</b></span></div><DepthMountain market={market} format={formatPrice} /><div className="ob-ladders"><DepthList title="Bids" side="bid" rows={market.depth.bids} format={formatPrice} onPick={(value) => { setSide('sell'); setPrice(formatUnits(value, priceDenom, priceDenom)); }} /><DepthList title="Asks" side="ask" rows={market.depth.asks} format={formatPrice} onPick={(value) => { setSide('buy'); setPrice(formatUnits(value, priceDenom, priceDenom)); }} /></div><div className="ob-trades"><header><span>Recent trades</span><i>Price</i><i>Qty</i><i>Total</i><i>Time</i></header>{marketTape.slice(-10).reverse().map(([at, tradePrice, count, bought], index) => <div key={`${at}-${index}`}><b className={bought ? 'buy' : 'sell'}>{bought ? 'BUY' : 'SELL'}</b><span>{formatPrice(tradePrice)}</span><span>{count}</span><span>{formatPrice(tradePrice * count)}</span><time>{new Date(at * 1000).toLocaleTimeString()}</time></div>)}</div></section>
      <aside className="ob-ticket ob-panel"><header><div><span className="ob-eyebrow">Order ticket</span><h3>{assetLabel(base)}</h3></div><span className="ob-fee">{config?.takerBps ? `${(config.takerBps / 100).toFixed(2)}% taker` : 'No fee'}</span></header><div className="ob-side"><button className={side === 'buy' ? 'active' : ''} onClick={() => setSide('buy')}>Bid</button><button className={side === 'sell' ? 'active' : ''} onClick={() => setSide('sell')}>Ask</button></div><div className="ob-tif">{TIFS.map((choice) => <button key={choice.value} className={tif === choice.value ? 'active' : ''} onClick={() => setTif(choice.value)}>{choice.label}</button>)}</div><p className="ob-tif-copy">{TIFS.find((choice) => choice.value === tif)?.copy}</p>
        {immediate ? <div className="ob-derived"><span className="ob-eyebrow">Limit from ladder</span><b>{sweep.price ? formatPrice(sweep.price) : '—'}</b></div> : <label><span>Unit price / {assetLabel(quote)}</span><input inputMode="decimal" value={price} onChange={(event) => setPrice(event.target.value)} /></label>}<label><span>Quantity</span><input inputMode="numeric" value={quantity} onChange={(event) => setQuantity(event.target.value)} /></label><dl className="ob-summary"><div><dt>Order value</dt><dd>{notional ? formatPrice(notional) : '—'}</dd></div><div><dt>Taker fee</dt><dd className={fee ? 'sell' : 'buy'}>{fee ? formatPrice(fee) : 'None'}</dd></div><div><dt>{assetLabel(quote)} committed</dt><dd>{notional ? formatPrice(notional + fee) : '—'}</dd></div>{market.band && <div><dt>Price band</dt><dd>{formatPrice(market.band.low)}–{formatPrice(market.band.high)}</dd></div>}</dl>{priceError && <p className="ob-warning">{priceError}</p>}{outsideBand && <p className="ob-warning">Outside the venue price band.</p>}
        {!account ? <button className="ob-submit" onClick={() => setWalletOpen(true)}>Connect to trade</button> : <button className="ob-submit" disabled={!!busy || !ready || info?.Paused} onClick={submit}>{busy === 'order' ? 'Settling…' : `Place ${side === 'buy' ? 'bid' : 'ask'}`}</button>}<div className="ob-list-head"><span>Your open orders</span>{orders.length > 1 && <button onClick={() => void execute('cancel-all', 'Orders cancelled.', () => client.cancelAll(market.base))}>Withdraw all</button>}</div><ul className="ob-orders">{orders.map((order: VenueOrder) => <li key={order.id}><b className={order.side === 'buy' ? 'buy' : 'sell'}>{order.side === 'buy' ? 'BID' : 'ASK'}</b><span>{order.remaining}/{order.quantity} @ {formatPrice(order.price)}</span><button onClick={() => void execute(`cancel-${order.id}`, 'Order cancelled.', () => client.cancel(order.id))}>×</button></li>)}{!orders.length && <li className="empty">Nothing of yours on the book.</li>}</ul><div className="ob-list-head"><span>Your recent fills</span></div><ul className="ob-fills">{fills.map((fill: VenueFill) => { const bought = fill.buyer === account; return <li key={fill.id}><b className={bought ? 'buy' : 'sell'}>{bought ? 'BUY' : 'SELL'}</b><span>{fill.quantity} @ {formatPrice(fill.price)}</span><time>{relative(fill.filledAt)}</time></li>; })}{!fills.length && <li className="empty">Nothing filled yet.</li>}</ul></aside></div> : <div className="ob-empty ob-panel">No launched market is available.</div>}
  </section>;
}
