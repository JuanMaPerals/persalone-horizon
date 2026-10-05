import { type ReactElement, useEffect, useState } from 'react';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';

const runtimeEventsUrl = 'http://127.0.0.1:47800/v1/runtime-events';

export function AccessibilityPanel(): ReactElement {
  const [live, setLive] = useState<LiveSnapshot | null>(null);

  useEffect(() => {
    const client = new RuntimeStreamClient({ url: runtimeEventsUrl, onChange: setLive });
    client.start();
    return () => client.stop();
  }, []);

  const connected = live?.connection === 'LIVE';
  const view = live?.view;
  const session = connected ? view?.sessionState ?? 'UNKNOWN' : 'UNKNOWN';
  const environment = connected ? view?.captionEnvironment ?? 'UNKNOWN' : 'UNKNOWN';
  const evidence = connected ? view?.captionTruth ?? 'UNKNOWN' : 'UNKNOWN';
  const delivered = connected ? view?.captions.delivered ?? 0 : 'UNKNOWN';
  const blocked = connected ? view?.captions.blocked ?? 0 : 'UNKNOWN';
  const failed = connected ? view?.captions.failed ?? 0 : 'UNKNOWN';
  const folded = connected ? view?.captionGlyphs.folded ?? 0 : 'UNKNOWN';
  const replaced = connected ? view?.captionGlyphs.replaced ?? 0 : 'UNKNOWN';
  const physicalCaption = connected && environment === 'HALO_REAL' && evidence === 'MEASURED';

  return <section className="accessibility-product" aria-label="Accessibility">
    <div className="accessibility-hero">
      <div>
        <span className="product-eyebrow">ACCESSIBILITY</span>
        <h1>Live captions with evidence.</h1>
        <p>HORIZON can route final translated turns to the caption path. This surface shows only redacted delivery evidence, never the spoken text.</p>
      </div>
      <div className={connected ? 'caption-proof live' : 'caption-proof'}>
        <span />
        <strong>{connected ? 'Caption evidence live' : 'Caption evidence unavailable'}</strong>
        <small>{connected ? 'Read-only runtime stream' : 'State stays UNKNOWN when evidence is absent'}</small>
      </div>
    </div>

    <div className="accessibility-grid">
      <article>
        <span className="product-eyebrow">SESSION</span>
        <strong>{session}</strong>
        <small>Started only through the authorized local runtime with explicit consent.</small>
      </article>
      <article>
        <span className="product-eyebrow">CAPTION PATH</span>
        <strong>{environment}</strong>
        <small>{physicalCaption ? 'Physical path measured.' : 'No physical-Halo claim without HALO_REAL + MEASURED evidence.'}</small>
      </article>
      <article>
        <span className="product-eyebrow">EVIDENCE</span>
        <strong>{evidence}</strong>
        <small>Evidence label comes from runtime events, not UI inference.</small>
      </article>
    </div>

    <div className="caption-delivery-card">
      <div className="caption-delivery-head">
        <div><span className="product-eyebrow">DELIVERY</span><h2>Caption outcomes</h2></div>
        <span>{connected ? 'LIVE' : 'UNKNOWN'}</span>
      </div>
      <dl>
        <div><dt>Delivered</dt><dd>{delivered}</dd></div>
        <div><dt>Blocked</dt><dd>{blocked}</dd></div>
        <div><dt>Failed</dt><dd>{failed}</dd></div>
        <div><dt>Accents folded</dt><dd>{folded}</dd></div>
        <div><dt>Glyphs replaced</dt><dd>{replaced}</dd></div>
      </dl>
      <p>The current Halo font path is ASCII-limited. HORIZON reports folding or replacement instead of claiming full Unicode rendering.</p>
    </div>

    <div className="accessibility-boundary">
      <div><strong>Local control only</strong><span>Microphone start, consent and language changes stay on the local companion. This web surface does not activate sensors.</span></div>
      <button type="button" disabled title="Accessibility session start is local-only">Start captions here</button>
    </div>
  </section>;
}
