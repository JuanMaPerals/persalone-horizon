import { type ReactElement, useState } from 'react';
import { CommunityLab } from './components/CommunityLab';
import { HelloHaloPanel } from './components/HelloHaloPanel';
import { RuntimeStatePanel } from './components/RuntimeStatePanel';
import { ConsolePanel } from './components/ConsolePanel';

type Workspace = 'home' | 'studio' | 'runtime' | 'observability' | 'privacy' | 'lab';

const workspaces: Array<{id: Workspace; label: string; hint: string}> = [
  { id: 'home', label: 'Home', hint: 'Product readiness and capability map' },
  { id: 'studio', label: 'Studio', hint: 'Build and exercise Halo apps' },
  { id: 'runtime', label: 'Runtime', hint: 'Live truth, latency and device state' },
  { id: 'observability', label: 'Observability', hint: 'Trace-derived operational evidence' },
  { id: 'privacy', label: 'Privacy', hint: 'Permissions and evidence boundaries' },
  { id: 'lab', label: 'Community Lab', hint: 'Safe simulated experiments' },
];

export default function App(): ReactElement {
  const [workspace, setWorkspace] = useState<Workspace>('home');
  return <main className="horizon-shell">
    <header className="mission-header">
      <div><span className="mission-kicker">PERSALONE HORIZON</span><h1>Mission Control</h1><p>Contextual computing · agent runtime · evidence-first operations</p></div>
      <div className="mission-health" aria-label="System evidence boundary"><span className="mission-pulse"/><div><strong>PUBLIC CONSOLE</strong><small>Hardware truth remains UNKNOWN until observed</small></div></div>
    </header>
    <nav className="mission-nav" aria-label="HORIZON workspaces">
      {workspaces.map(item => <button key={item.id} type="button" className={workspace === item.id ? 'is-active' : ''} onClick={() => setWorkspace(item.id)}><strong>{item.label}</strong><span>{item.hint}</span></button>)}
    </nav>
    <section className="mission-summary" aria-label="HORIZON status summary">
      <article><span>Product surface</span><strong>ONLINE</strong><small>GitHub Pages</small></article>
      <article><span>Runtime source</span><strong>CONNECTABLE</strong><small>SSE / offline evidence</small></article>
      <article><span>Digital twin</span><strong>EMULATED</strong><small>Official emulator path</small></article>
      <article><span>Physical Halo</span><strong>UNKNOWN</strong><small>Awaiting hardware evidence</small></article>
    </section>
    <section className="mission-workspace" data-workspace={workspace}>
      {workspace === 'home' && <section className="product-home" aria-label="HORIZON product readiness"><h2>HORIZON is one product, not a dashboard collection</h2><p className="product-lead">Build, run and observe contextual applications against the official Halo emulator while preserving explicit evidence boundaries.</p><div className="capability-grid"><article><span>Device</span><strong>Halo adapter</strong><small>Official emulator verified · physical hardware not yet observed</small></article><article><span>Agents</span><strong>Runtime capabilities</strong><small>Translation, vision, cognitive assistance and display contracts</small></article><article><span>Activity</span><strong>Canonical runtime stream</strong><small>Read-only SSE with fail-closed UNKNOWN state</small></article><article><span>Evidence</span><strong>Observable by design</strong><small>Metrics, traces, diagnostics and recovery without transcript leakage</small></article></div><div className="home-actions"><button type="button" onClick={() => setWorkspace('studio')}>Open Studio</button><button type="button" onClick={() => setWorkspace('runtime')}>Inspect Runtime</button><button type="button" onClick={() => setWorkspace('privacy')}>Review Privacy</button></div></section>}
      {workspace === 'studio' && <HelloHaloPanel />}
      {workspace === 'runtime' && <RuntimeStatePanel />}
      {workspace === 'observability' && <div className="observability-grid"><ConsolePanel panelId="metrics"/><ConsolePanel panelId="translation"/><ConsolePanel panelId="ble-monitor"/><ConsolePanel panelId="memory-rag"/></div>}
      {workspace === 'privacy' && <section className="privacy-panel" aria-label="Privacy and permissions"><h2>Privacy & Permissions</h2><div className="capability-grid"><article><span>Runtime events</span><strong>READ ONLY</strong><small>Controls remain denied until an authenticated bounded control API exists.</small></article><article><span>Memory</span><strong>DISABLED BY DEFAULT</strong><small>Raw audio, unredacted transcripts, identifiers and credentials are excluded.</small></article><article><span>Observability</span><strong>AGGREGATE ONLY</strong><small>Prometheus metrics expose counters and health, not user content.</small></article><article><span>Hardware claim</span><strong>FAIL CLOSED</strong><small>Physical Halo stays UNKNOWN until hardware-observed evidence exists.</small></article></div></section>}
      {workspace === 'lab' && <CommunityLab />}
    </section>
  </main>;
}
