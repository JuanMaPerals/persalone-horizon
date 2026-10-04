import { type ReactElement, useEffect, useRef, useState } from 'react';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';

const runtimeEventsUrl = 'http://127.0.0.1:47800/v1/runtime-events';

export function TranslatePanel(): ReactElement {
  const [live, setLive] = useState<LiveSnapshot | null>(null);
  const clientRef = useRef<RuntimeStreamClient | null>(null);

  useEffect(() => {
    const client = new RuntimeStreamClient({ url: runtimeEventsUrl, onChange: setLive });
    clientRef.current = client;
    client.start();
    return () => client.stop();
  }, []);

  const connected = live?.connection === 'LIVE';
  const view = live?.view;
  const runtimeState = connected ? view?.sessionState ?? 'UNKNOWN' : 'UNKNOWN';
  const environment = connected ? view?.captionEnvironment ?? 'UNKNOWN' : 'UNKNOWN';
  const evidence = connected ? view?.captionTruth ?? 'UNKNOWN' : 'UNKNOWN';
  const device = connected ? view?.deviceState ?? 'UNKNOWN' : 'UNKNOWN';
  const delivered = connected ? view?.captions.delivered ?? 0 : 'UNKNOWN';

  return <section className="translate-product" aria-label="Translate">
    <div className="translate-hero">
      <div>
        <span className="product-eyebrow">LIVE TRANSLATION</span>
        <h1>Translate conversations.<br />Keep the context yours.</h1>
        <p>The translation pipeline runs through the local HORIZON runtime. Starting a microphone session requires explicit consent on the local device.</p>
      </div>
      <div className={connected ? 'runtime-orb live' : 'runtime-orb'}>
        <span />
        <strong>{connected ? 'Runtime live' : 'Runtime unavailable'}</strong>
        <small>{connected ? 'Read-only evidence connected' : 'No live state is inferred'}</small>
      </div>
    </div>

    <div className="translate-direction" aria-label="Translation direction">
      <div><small>FROM</small><strong>English</strong></div>
      <span>→</span>
      <div><small>TO</small><strong>Spanish</strong></div>
      <span className="local-only">Changes apply locally</span>
    </div>

    <div className="translate-grid">
      <article className="translate-session-card">
        <span className="product-eyebrow">SESSION</span>
        <h2>{runtimeState === 'listening' ? 'Listening' : runtimeState === 'UNKNOWN' ? 'No verified session' : runtimeState}</h2>
        <p>HORIZON will never start your microphone from this remote web surface. Start consent and language selection stay on the local companion.</p>
        <div className="translate-actions">
          <button type="button" disabled title="START is intentionally local-only">Start on this browser</button>
          <span>Local consent required</span>
        </div>
      </article>
      <article className="translate-evidence-card">
        <span className="product-eyebrow">LIVE EVIDENCE</span>
        <dl>
          <div><dt>Runtime</dt><dd>{runtimeState}</dd></div>
          <div><dt>Device</dt><dd>{device}</dd></div>
          <div><dt>Caption path</dt><dd>{environment}</dd></div>
          <div><dt>Evidence</dt><dd>{evidence}</dd></div>
          <div><dt>Captions delivered</dt><dd>{delivered}</dd></div>
        </dl>
        <small className="evidence-note">No transcript or translation text is exposed through this evidence stream.</small>
      </article>
    </div>

    <div className="translate-privacy">
      <strong>Privacy boundary</strong>
      <span>Audio and transcript content are not persisted by this panel. Runtime telemetry is redacted.</span>
    </div>
  </section>;
}
