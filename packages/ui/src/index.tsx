import type { VenueBook, VenueInfo } from '@runerealm/orderbook-client';

export function MarketOverview({ info, book }: { info: VenueInfo | null; book: VenueBook | null }) {
  const markets = Object.values(book ?? {}).sort((a, b) => a.id.localeCompare(b.id));
  return (
    <section className="market-overview" aria-label="Live orderbook markets">
      <header>
        <div>
          <span className="eyebrow">Live venue</span>
          <h2>{info?.Name ?? 'Orderbook'}</h2>
        </div>
        <span className={`status ${info?.Paused ? 'paused' : 'open'}`}>
          {info?.Paused ? 'Paused' : info ? 'Open' : 'Connecting'}
        </span>
      </header>
      {markets.length ? (
        <div className="market-grid">
          {markets.map((market) => (
            <article className="market-row" key={market.id}>
              <div>
                <strong>{market.base} / {market.quote}</strong>
                <small>{market.status}</small>
              </div>
              <dl>
                <div><dt>Bid</dt><dd>{market.bestBid ?? '—'}</dd></div>
                <div><dt>Ask</dt><dd>{market.bestAsk ?? '—'}</dd></div>
                <div><dt>Orders</dt><dd>{[...market.depth.bids, ...market.depth.asks]
                  .reduce((sum, level) => sum + level.orders, 0)}</dd></div>
              </dl>
            </article>
          ))}
        </div>
      ) : <p className="empty">No launched markets are published yet.</p>}
    </section>
  );
}
