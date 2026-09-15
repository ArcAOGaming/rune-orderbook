import { useCallback, useEffect, useState } from 'react';
import {
  createVenueClient, type VenueBook, type VenueInfo,
} from '@runerealm/orderbook-client';
import { MarketOverview } from '@runerealm/orderbook-ui';

const NODE = import.meta.env.VITE_ORDERBOOK_NODE || 'https://hyperbeam.tylerw.ai';
const PROCESS = import.meta.env.VITE_ORDERBOOK_PROCESS
  || 'g9deoTqVy9Uf7fKDZunf4alfbRh0LXE01uyg1czgrn4';
const RUNE_REALM_URL = import.meta.env.VITE_RUNE_REALM_URL?.trim();

export default function App() {
  const [info, setInfo] = useState<VenueInfo | null>(null);
  const [book, setBook] = useState<VenueBook | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const client = createVenueClient({ node: NODE, process: PROCESS });
      const [nextInfo, nextBook] = await Promise.all([client.info(), client.book()]);
      setInfo(nextInfo);
      setBook(nextBook);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);

  return (
    <main>
      <nav><span className="mark"><b>R</b></span><strong>Rune Orderbook</strong>
        {RUNE_REALM_URL && <a href={RUNE_REALM_URL}>Enter Rune Realm</a>}
      </nav>
      <section className="hero">
        <span className="eyebrow">Price · time · custody</span>
        <h1>A public market<br />with nothing hidden.</h1>
        <p>Read the live book without a wallet. Deposit only when you are ready to quote, trade, or withdraw.</p>
        <div className="actions"><a href="#markets">View markets</a><button onClick={() => void refresh()} disabled={loading}>{loading ? 'Reading…' : 'Refresh'}</button></div>
      </section>
      {error && <p className="error" role="alert">{error}</p>}
      <div id="markets"><MarketOverview info={info} book={book} /></div>
      <footer>Phase one is read-only. Signed custody and the full trading floor arrive after the AO package boundary is proven.</footer>
    </main>
  );
}
