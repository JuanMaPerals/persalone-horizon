import { type ReactElement, useEffect, useState } from 'react';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';
import { runtimeEventsUrl } from '../runtime/runtimeEndpoint';
export function MyHaloPanel(): ReactElement {
  const [live, setLive] = useState<LiveSnapshot | null>(null);
  useEffect(() => { const client = new RuntimeStreamClient({ url: runtimeEventsUrl(), onChange: setLive }); client.start(); return () => client.stop(); }, []);
  const isLive = live?.connection === 'LIVE';
  const view = live?.view;
  const degraded = isLive && view?.degraded === true;
  const trustworthy = isLive && !degraded;
  const state = trustworthy ? view?.deviceState ?? 'UNKNOWN' : 'UNKNOWN';
  const environment = trustworthy ? view?.deviceEnvironment ?? 'UNKNOWN' : 'UNKNOWN';
  const evidence = trustworthy ? view?.deviceTruth ?? 'UNKNOWN' : 'UNKNOWN';
  const physicalObserved = trustworthy && environment === 'HALO_REAL' && evidence === 'MEASURED';
  const emulatorObserved = trustworthy && environment === 'EMULATED';
  return <section className="my-halo-product" aria-label="My Halo">
    <div className="my-halo-hero"><div><span className="product-eyebrow">DEVICE</span><h1>My Halo</h1><p>One place for the device path HORIZON can actually prove. Emulator evidence and physical-hardware evidence are never mixed.</p></div>
      <div className={physicalObserved ? 'halo-proof observed' : 'halo-proof'}><span className="halo-proof-ring"><i /></span><strong>{physicalObserved ? 'Physical Halo observed' : 'Physical Halo not observed'}</strong><small>{physicalObserved ? 'Measured runtime evidence' : 'No hardware claim without device evidence'}</small></div></div>
    <div className="device-proof-grid">
      <article><span className="product-eyebrow">PHYSICAL HALO</span><strong>{physicalObserved ? state : 'UNKNOWN'}</strong><small>{physicalObserved ? environment + ' · ' + evidence : 'Requires HALO_REAL + MEASURED evidence.'}</small></article>
      <article><span className="product-eyebrow">EMULATOR</span><strong>{emulatorObserved ? state : 'VERIFIED IN CI'}</strong><small>{emulatorObserved ? environment + ' · ' + evidence : 'Emulated path is tested separately from hardware.'}</small></article>
      <article><span className="product-eyebrow">OFFICIAL TRANSPORT</span><strong>PREPARED</strong><small>Discovery, connect, reconnect and link-state code exists. Prepared does not mean physically verified.</small></article>
    </div>
    <div className="device-live-card"><div className="device-live-head"><div><span className={isLive && !degraded ? 'status-led is-live' : degraded ? 'status-led is-degraded' : 'status-led'} /><strong>Runtime evidence</strong></div><span>{degraded ? 'DEGRADED' : isLive ? 'LIVE' : 'UNAVAILABLE'}</span></div>
      <dl><div><dt>Device state</dt><dd>{state}</dd></div><div><dt>Environment</dt><dd>{environment}</dd></div><div><dt>Evidence</dt><dd>{evidence}</dd></div><div><dt>Stream</dt><dd>{isLive ? live?.streamId ?? 'UNKNOWN' : 'UNKNOWN'}</dd></div></dl>
      <p>{degraded ? 'Runtime evidence is incomplete, so device-derived values are reported as UNKNOWN.' : 'This web panel observes redacted runtime state only. It does not perform Bluetooth discovery or claim a physical connection.'}</p></div>
    <div className="device-next-step"><div><strong>Physical validation</strong><span>Discovery and connection must be executed on the authorized local device path.</span></div><button type="button" disabled title="Physical discovery is local-only">Discover from browser</button></div>
  </section>;
}
