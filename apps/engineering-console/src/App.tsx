import { type ReactElement, useState } from 'react';
import { HelloHaloPanel } from './components/HelloHaloPanel';
import { TranslatePanel } from './components/TranslatePanel';
import { MyHaloPanel } from './components/MyHaloPanel';

type Panel = 'home' | 'device' | 'translate' | 'accessibility' | 'meetings' | 'vision' | 'security' | 'privacy';

const panels: Array<{id: Panel; label: string; glyph: string}> = [
  { id: 'home', label: 'Home', glyph: '⌂' },
  { id: 'device', label: 'My Halo', glyph: '◉' },
  { id: 'translate', label: 'Translate', glyph: '文' },
  { id: 'accessibility', label: 'Accessibility', glyph: 'A' },
  { id: 'meetings', label: 'Meetings', glyph: '◫' },
  { id: 'vision', label: 'Vision', glyph: '◎' },
  { id: 'security', label: 'Security', glyph: '◇' },
  { id: 'privacy', label: 'Privacy', glyph: '○' },
];

const capabilities: Array<{id: Panel; title: string; description: string; state: string; tone: string}> = [
  { id: 'translate', title: 'Translate', description: 'Live speech, captions and translation pipeline.', state: 'Software path verified', tone: 'ready' },
  { id: 'accessibility', title: 'Accessibility', description: 'Contextual assistance designed around what you need now.', state: 'Not connected yet', tone: 'quiet' },
  { id: 'meetings', title: 'Meetings', description: 'Follow conversations and keep useful context within your control.', state: 'Not connected yet', tone: 'quiet' },
  { id: 'vision', title: 'Vision', description: 'Understand what is in front of you with explicit permission.', state: 'Not connected yet', tone: 'quiet' },
  { id: 'security', title: 'Security', description: 'Surface security context without exposing private content.', state: 'Not connected yet', tone: 'quiet' },
];

function Home({open}: {open: (panel: Panel) => void}): ReactElement {
  return <div className="product-home">
    <section className="hero-card">
      <div>
        <span className="product-eyebrow">YOUR CONTEXT, YOUR CONTROL</span>
        <h1>Good evening.</h1>
        <p>HORIZON brings your Halo capabilities together in one private workspace.</p>
      </div>
      <button className="halo-status-card" type="button" onClick={() => open('device')}>
        <span className="halo-orbit"><i /></span>
        <span><strong>My Halo</strong><small>Physical device not observed</small></span>
        <b>›</b>
      </button>
    </section>
    <section className="section-heading">
      <div><span className="product-eyebrow">CAPABILITIES</span><h2>What do you want to do?</h2></div>
      <button className="text-action" type="button" onClick={() => open('privacy')}>Privacy controls</button>
    </section>
    <section className="capability-grid">
      {capabilities.map(cap => <button className="capability-card" key={cap.id} type="button" onClick={() => open(cap.id)}>
        <span className={"capability-icon " + cap.id}>{panels.find(p => p.id === cap.id)?.glyph}</span>
        <span className="capability-copy"><strong>{cap.title}</strong><small>{cap.description}</small></span>
        <span className={"capability-state " + cap.tone}>{cap.state}</span>
        <b>›</b>
      </button>)}
    </section>
    <section className="privacy-strip">
      <span className="privacy-lock">⌾</span>
      <div><strong>Private by default</strong><small>Memory stays off until you enable it. Hardware claims remain unknown until a real device is observed.</small></div>
      <button type="button" onClick={() => open('privacy')}>Review</button>
    </section>
  </div>;
}

function CapabilityPanel({panel, back}: {panel: Panel; back: () => void}): ReactElement {
  const item = capabilities.find(cap => cap.id === panel);
  if (panel === 'translate') return <div className="product-detail translate-detail"><button className="back-button" type="button" onClick={back}>‹ Home</button><TranslatePanel /></div>;
  if (panel === 'device') return <div className="product-detail"><button className="back-button" type="button" onClick={back}>‹ Home</button><MyHaloPanel /><details className="engineering-tools"><summary>Developer emulator tools</summary><div className="embedded-real-path"><HelloHaloPanel /></div></details></div>;
  if (panel === 'privacy') return <div className="product-detail"><button className="back-button" type="button" onClick={back}>‹ Home</button><div className="detail-heading"><span className="product-eyebrow">PRIVACY & PERMISSIONS</span><h1>You decide what HORIZON can use.</h1><p>Permissions fail closed. Memory is disabled by default and observability uses aggregate evidence only.</p></div><div className="permission-list"><article><div><strong>Memory</strong><small>Persistent contextual memory</small></div><span className="off-pill">OFF</span></article><article><div><strong>Runtime activity</strong><small>Read-only operational events</small></div><span className="read-pill">READ ONLY</span></article><article><div><strong>Observability</strong><small>Aggregate metrics, no transcript content</small></div><span className="read-pill">AGGREGATE</span></article><article><div><strong>Physical Halo</strong><small>Requires hardware-observed evidence</small></div><span className="unknown-pill">UNKNOWN</span></article></div></div>;
  return <div className="product-detail"><button className="back-button" type="button" onClick={back}>‹ Home</button><div className="detail-heading"><span className="product-eyebrow">CAPABILITY</span><h1>{item?.title}</h1><p>{item?.description}</p></div><div className="capability-boundary"><span className="capability-icon large">{panels.find(p => p.id === panel)?.glyph}</span><div><strong>{item?.state}</strong><p>This panel will only expose actions when its real execution path is connected. No simulated success and no dead controls.</p></div></div></div>;
}

export default function App(): ReactElement {
  const [panel, setPanel] = useState<Panel>('home');
  return <main className="product-shell">
    <aside className="product-sidebar">
      <button className="product-brand" type="button" onClick={() => setPanel('home')} aria-label="HORIZON Home"><span>H</span><strong>HORIZON</strong></button>
      <nav aria-label="HORIZON navigation">{panels.map(item => <button key={item.id} type="button" aria-label={item.label} className={panel === item.id ? 'active' : ''} onClick={() => setPanel(item.id)} title={item.label}><span>{item.glyph}</span><small>{item.label}</small></button>)}</nav>
      <div className="sidebar-foot"><span className="privacy-dot" /><small>Private</small></div>
    </aside>
    <section className="product-content">
      <header className="product-topbar"><div><strong>PersalOne HORIZON</strong><small>Contextual computing</small></div><span className="truth-chip">HALO · NOT OBSERVED</span></header>
      {panel === 'home' ? <Home open={setPanel} /> : <CapabilityPanel panel={panel} back={() => setPanel('home')} />}
    </section>
  </main>;
}
