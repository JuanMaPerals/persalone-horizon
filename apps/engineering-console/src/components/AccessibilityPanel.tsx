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
  const physicalCaption = connected && environment === 'HALO_REAL' && evidence === 'MEASURED';

  return <section aria-label="Accessibility">
    <div className="detail-heading">
      <span className="product-eyebrow">ACCESSIBILITY</span>
      <h1>Live captions with evidence.</h1>
      <p>HORIZON exposes redacted caption-delivery evidence only. Spoken text is not surfaced by this web panel.</p>
    </div>
    <div className="permission-list">
      <article><div><strong>Runtime session</strong><small>Authorized local runtime only</small></div><span className={connected ? 'read-pill' : 'unknown-pill'}>{session}</span></article>
      <article><div><strong>Caption path</strong><small>{physicalCaption ? 'Physical Halo path measured' : 'No physical claim without HALO_REAL + MEASURED'}</small></div><span className={physicalCaption ? 'read-pill' : 'unknown-pill'}>{environment}</span></article>
      <article><div><strong>Evidence</strong><small>Runtime truth label</small></div><span className={evidence === 'MEASURED' ? 'read-pill' : 'unknown-pill'}>{evidence}</span></article>
      <article><div><strong>Caption outcomes</strong><small>Delivered / blocked / failed</small></div><span className="read-pill">{String(delivered)} / {String(blocked)} / {String(failed)}</span></article>
    </div>
    <div className="capability-boundary">
      <span className="capability-icon large">A</span>
      <div>
        <strong>Local control only</strong>
        <p>Microphone start, consent and language changes stay on the local companion. This browser does not activate sensors or infer a physical Halo connection.</p>
      </div>
    </div>
  </section>;
}
