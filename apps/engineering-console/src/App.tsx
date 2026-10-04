import { type ReactElement, useState } from 'react';
import { CommunityLab } from './components/CommunityLab';
import { HelloHaloPanel } from './components/HelloHaloPanel';
import { RuntimeStatePanel } from './components/RuntimeStatePanel';
import { ConsolePanel } from './components/ConsolePanel';

type Workspace = 'studio' | 'runtime' | 'observability' | 'lab';

const workspaces: Array<{id: Workspace; label: string; hint: string}> = [
  { id: 'studio', label: 'Studio', hint: 'Build and exercise Halo apps' },
  { id: 'runtime', label: 'Runtime', hint: 'Live truth, latency and device state' },
  { id: 'observability', label: 'Observability', hint: 'Trace-derived operational evidence' },
  { id: 'lab', label: 'Community Lab', hint: 'Safe simulated experiments' },
];

export default function App(): ReactElement {
  const [workspace, setWorkspace] = useState<Workspace>('studio');
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
      {workspace === 'studio' && <HelloHaloPanel />}
      {workspace === 'runtime' && <RuntimeStatePanel />}
      {workspace === 'observability' && <div className="observability-grid"><ConsolePanel panelId="metrics"/><ConsolePanel panelId="translation"/><ConsolePanel panelId="ble-monitor"/><ConsolePanel panelId="memory-rag"/></div>}
      {workspace === 'lab' && <CommunityLab />}
    </section>
  </main>;
}
