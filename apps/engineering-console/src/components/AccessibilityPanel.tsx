import { type ReactElement, useEffect, useState } from 'react';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';
import { runtimeEventsUrl } from '../runtime/runtimeEndpoint';

export function AccessibilityPanel(): ReactElement {
  const [live, setLive] = useState<LiveSnapshot | null>(null);

  useEffect(() => {
    const client = new RuntimeStreamClient({ url: runtimeEventsUrl(), onChange: setLive });
    client.start();
    return () => client.stop();
  }, []);

  const connected = live?.connection === 'LIVE';
  const view = live?.view;
  const degraded = connected && view?.degraded === true;
  const trustworthy = connected && !degraded;
  const session = trustworthy ? view?.sessionState ?? 'UNKNOWN' : 'UNKNOWN';
  const environment = trustworthy ? view?.captionEnvironment ?? 'UNKNOWN' : 'UNKNOWN';
  const evidence = trustworthy ? view?.captionTruth ?? 'UNKNOWN' : 'UNKNOWN';
  const delivered: string | number = degraded ? 'PARTIAL' : trustworthy ? view?.captions.delivered ?? 0 : 'UNKNOWN';
  const blocked: string | number = degraded ? 'PARTIAL' : trustworthy ? view?.captions.blocked ?? 0 : 'UNKNOWN';
  const failed: string | number = degraded ? 'PARTIAL' : trustworthy ? view?.captions.failed ?? 0 : 'UNKNOWN';
  const physicalCaption = trustworthy && environment === 'HALO_REAL' && evidence === 'MEASURED';

  return <section aria-label="Accessibility">
    <div className="detail-heading">
      <span className="product-eyebrow">ACCESSIBILITY</span>
      <h1>Live captions with evidence.</h1>
      <p>HORIZON exposes redacted caption-delivery evidence only. Spoken text is not surfaced by this web panel.</p>
    </div>
    <div className="permission-list">
      <article>
        <div>
          <strong>Runtime session</strong>
          <small>{degraded ? 'Evidence incomplete; state fails closed' : 'Authorized local runtime only'}</small>
        </div>
        <span className={trustworthy ? 'read-pill' : 'unknown-pill'}>{session}</span>
      </article>
      <article>
        <div>
          <strong>Caption path</strong>
          <small>{physicalCaption ? 'Physical Halo path measured' : 'No physical claim without HALO_REAL + MEASURED'}</small>
        </div>
        <span className={physicalCaption ? 'read-pill' : 'unknown-pill'}>{environment}</span>
      </article>
      <article>
        <div>
          <strong>Evidence</strong>
          <small>Runtime truth label</small>
        </div>
        <span className={evidence === 'MEASURED' ? 'read-pill' : 'unknown-pill'}>{evidence}</span>
      </article>
      <article>
        <div>
          <strong>Caption outcomes</strong>
          <small>{degraded ? 'Partial evidence; counts are not authoritative' : 'Delivered / blocked / failed'}</small>
        </div>
        <span className={trustworthy ? 'read-pill' : 'unknown-pill'}>{String(delivered)} / {String(blocked)} / {String(failed)}</span>
      </article>
    </div>
    <div className="capability-boundary">
      <span className="capability-icon large" aria-hidden="true">A</span>
      <div>
        <strong>Local control only</strong>
        <p>Microphone start, consent and language changes stay on the local companion. This browser does not activate sensors or infer a physical Halo connection.</p>
      </div>
    </div>
  </section>;
}
