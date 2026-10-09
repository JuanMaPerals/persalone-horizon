import { type ReactElement, useEffect, useState } from 'react';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';
import { runtimeEventsUrl } from '../runtime/runtimeEndpoint';
import { RemoteControlPanel } from './RemoteControlPanel';

export function SecurityPanel(): ReactElement {
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
  const runtimeState = trustworthy ? view?.sessionState ?? 'UNKNOWN' : 'UNKNOWN';
  const deviceState = trustworthy ? view?.deviceState ?? 'UNKNOWN' : 'UNKNOWN';
  const errorCount: string | number = degraded ? 'PARTIAL' : trustworthy ? view?.errorCount ?? 0 : 'UNKNOWN';
  const lastError = !trustworthy
    ? 'UNKNOWN'
    : view?.lastError
      ? `${view.lastError.code}${view.lastError.component ? ` · ${view.lastError.component}` : ''}`
      : 'NONE OBSERVED';
  const failureCode = trustworthy ? view?.failureCode ?? 'NONE OBSERVED' : 'UNKNOWN';

  return <section className="security-product" aria-label="Security">
    <div className="security-hero">
      <div>
        <span className="product-eyebrow">SECURITY</span>
        <h1>Stop safely. Know what failed.</h1>
        <p>HORIZON exposes redacted runtime safety evidence and an opt-in authenticated local channel for STOP and PANIC. START, language and device changes remain local-only.</p>
      </div>
      <div className={trustworthy ? 'security-proof live' : degraded ? 'security-proof degraded' : 'security-proof'}>
        <span aria-hidden="true" />
        <strong>{degraded ? 'Evidence degraded' : trustworthy ? 'Runtime evidence live' : 'Runtime evidence unavailable'}</strong>
        <small>{degraded ? 'Security-derived state fails closed' : trustworthy ? 'Read-only evidence connected' : 'No state is inferred without evidence'}</small>
      </div>
    </div>

    <div className="security-grid">
      <article>
        <span className="product-eyebrow">SESSION</span>
        <strong>{runtimeState}</strong>
        <small>Runtime session state from the redacted evidence stream.</small>
      </article>
      <article>
        <span className="product-eyebrow">DEVICE</span>
        <strong>{deviceState}</strong>
        <small>No physical-device claim is inferred from control availability.</small>
      </article>
      <article>
        <span className="product-eyebrow">ERRORS</span>
        <strong>{String(errorCount)}</strong>
        <small>{lastError}</small>
      </article>
      <article>
        <span className="product-eyebrow">FAILURE CODE</span>
        <strong>{failureCode}</strong>
        <small>Only coded operational evidence is shown. No transcript content.</small>
      </article>
    </div>

    <div className="security-control-card">
      <div className="security-control-heading">
        <div>
          <span className="product-eyebrow">LOCAL EMERGENCY CONTROL</span>
          <h2>Authenticated STOP / PANIC</h2>
        </div>
        <span className="local-only">LOOPBACK ONLY</span>
      </div>
      <p className="security-control-copy">The phone control channel is opt-in, binds to loopback, requires a per-launch bearer credential and accepts only the actions explicitly enabled by policy. The credential is kept in browser memory only and is never rendered back into the page.</p>
      <RemoteControlPanel key={connected ? live?.streamId ?? 'unknown' : 'unknown'} expectedTargetId={connected ? live?.streamId ?? null : null} />
    </div>

    <div className="security-boundary">
      <strong>Fail closed</strong>
      <span>Unauthenticated, off-loopback, stale, replayed, expired or disallowed commands are refused before they can become a runtime action.</span>
    </div>
  </section>;
}
