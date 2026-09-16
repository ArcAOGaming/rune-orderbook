import { configureWallet } from '@runerealm/orderbook-client';
import { OrderbookTerminal } from '@runerealm/orderbook-ui';
import '@runerealm/orderbook-ui/style.css';

const NODE = import.meta.env.VITE_ORDERBOOK_NODE || 'https://hyperbeam.tylerw.ai';
const PROCESS = import.meta.env.VITE_ORDERBOOK_PROCESS
  || 'Q9E-ONGRPdZy-166rXBQCyPK1YMoyUobqwIRiHFiKNg';
const RUNE_REALM_URL = import.meta.env.VITE_RUNE_REALM_URL?.trim();

configureWallet({ appName: 'Rune Orderbook', storageNamespace: 'rune-orderbook' });

export default function App() {
  return <main>
    <nav><a className="brand" href="#top" aria-label="Rune Orderbook home"><span className="mark"><b>R</b></span>
      <span><strong>Rune</strong><small>Orderbook</small></span></a>
      <div className="nav-links"><a href="#markets">Markets</a><a href="#how">Protocol</a>
        {RUNE_REALM_URL && <a className="realm-link" href={RUNE_REALM_URL}>Rune Realm ↗</a>}</div></nav>
    <header className="hero" id="top"><div className="hero-copy"><span className="eyebrow">HyperBEAM limit markets</span>
      <h1>The book is<br /><em>the market.</em></h1>
      <p>Public price-time priority with deposit-first custody. Read every quote without a wallet. Connect only when you want to place, cancel, deposit or withdraw.</p>
      <div className="hero-actions"><a href="#markets">Open the live book</a><a className="quiet" href="#how">How settlement works</a></div></div>
      <div className="hero-ledger" aria-label="Protocol properties"><span>01</span><b>Price before time</b><p>Best price fills first. Equal prices keep their queue order.</p>
        <span>02</span><b>Funds before orders</b><p>Every resting order is fully backed by venue custody.</p>
        <span>03</span><b>Exit stays open</b><p>Cancel releases escrow immediately. Withdraw only what is free.</p></div></header>
    <section id="markets" className="terminal-wrap"><div className="section-heading"><div><span className="eyebrow">Live instrument</span><h2>Rune / Relic</h2></div>
      <p>The first listed pair proves the generic path. Markets, assets, ticks, lots and fees come from the venue registry—not this page.</p></div>
      <OrderbookTerminal node={NODE} process={PROCESS} />
    </section>
    <section id="how" className="protocol"><div className="section-heading"><div><span className="eyebrow">One engine, explicit custody</span><h2>Nothing fills behind your back.</h2></div>
      <p>The venue is an account ledger, not a pool. Deposits cross one process boundary; matching and settlement are atomic inside the book.</p></div>
      <div className="protocol-grid"><article><span>Deposit</span><h3>Move the asset once.</h3><p>The token emits a referenced credit notice. Duplicate delivery cannot credit twice.</p></article>
        <article><span>Quote</span><h3>Choose the worst price.</h3><p>Limit, immediate-or-cancel, fill-or-kill and maker-only orders all remain explicitly priced.</p></article>
        <article><span>Match</span><h3>The maker sets the price.</h3><p>A crossing order receives the resting quote and any improvement along the ladder.</p></article>
        <article><span>Withdraw</span><h3>Only free balance leaves.</h3><p>Cancel first to unlock escrow. Referenced outbox delivery makes retries observable.</p></article></div>
    </section>
    <footer><div><strong>Rune Orderbook</strong><span>Generic markets on HyperBEAM</span></div>
      <code>{PROCESS}</code></footer>
  </main>;
}
