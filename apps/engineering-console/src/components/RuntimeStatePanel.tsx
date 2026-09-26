import { type ChangeEvent, type ReactElement, useEffect, useRef, useState } from 'react';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';
import {
  parseRuntimeEventStream,
  reduceRuntimeEvents,
  runtimeControlAvailability,
  type RuntimeControl,
  type RuntimeView,
} from '../runtime/runtimeEvents';

const controls: readonly RuntimeControl[] = ['start', 'stop', 'panic'];
const defaultUrl = 'http://127.0.0.1:47800/v1/runtime-events';

export function RuntimeStatePanel(): ReactElement {
  const [url, setUrl] = useState(defaultUrl);
  const [live, setLive] = useState<LiveSnapshot | null>(null);
  const [fileView, setFileView] = useState<{ name: string; view: RuntimeView } | null>(null);
  const clientRef = useRef<RuntimeStreamClient | null>(null);

  useEffect(() => () => clientRef.current?.stop(), []);

  const connect = () => {
    clientRef.current?.stop();
    setFileView(null);
    const client = new RuntimeStreamClient({ url, onChange: setLive });
    clientRef.current = client;
    client.start();
  };

  const disconnect = () => {
    clientRef.current?.stop();
    clientRef.current = null;
    setLive(null);
  };

  const load = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;
    disconnect();
    setFileView({ name: file.name, view: reduceRuntimeEvents(parseRuntimeEventStream(await file.text())) });
  };

  // Live state wins; when not LIVE the client already returns UNKNOWN fields.
  const view: RuntimeView | null = live ? live.view : fileView?.view ?? null;
  const source = live
    ? `LIVE STREAM · ${live.connection}${live.reason ? ` (${live.reason})` : ''}`
    : fileView
      ? `OFFLINE FILE · ${fileView.name} (not live)`
      : 'NO SOURCE · all state UNKNOWN';
  const value = <T,>(read: (v: RuntimeView) => T): T | 'UNKNOWN' => (view ? read(view) : 'UNKNOWN');

  return <section className="monitor-panel">
    <div className="monitor-status" role="status">
      <span className={live?.connection === 'LIVE' ? 'status-led is-live' : 'status-led'} />
      {source}
    </div>
    <div className="runtime-source">
      <label>
        <span>Runtime event stream URL (read-only)</span>
        <input value={url} onChange={(event) => setUrl(event.target.value)} spellCheck={false} />
      </label>
      <button type="button" onClick={connect}>Connect</button>
      <button type="button" onClick={disconnect} disabled={!live}>Disconnect</button>
      <label>
        <span>Or load an offline .ndjson file</span>
        <input type="file" accept=".ndjson,application/x-ndjson" onChange={(event) => void load(event)} />
      </label>
    </div>
    {view?.degraded ? <p role="alert">DEGRADED: {view.rejectedLines} rejected event(s), {view.sequenceGaps} sequence gap(s) or truncated history.</p> : null}
    <dl className="metric-list">
      <div><dt>Session</dt><dd>{value((v) => v.sessionId)}</dd></div>
      <div><dt>Runtime state</dt><dd>{value((v) => v.sessionState)}{view?.failureCode ? ` (${view.failureCode})` : ''}</dd></div>
      <div><dt>Caption environment</dt><dd>{value((v) => v.captionEnvironment)}</dd></div>
      <div><dt>Caption evidence</dt><dd>{value((v) => v.captionTruth)}</dd></div>
      <div><dt>Captions delivered / blocked / failed</dt><dd>{view ? `${view.captions.delivered} / ${view.captions.blocked} / ${view.captions.failed}` : 'UNKNOWN'}</dd></div>
      <div><dt>Device link</dt><dd>{value((v) => v.deviceState)}</dd></div>
      <div><dt>Device environment</dt><dd>{value((v) => v.deviceEnvironment)}</dd></div>
      <div><dt>Device evidence</dt><dd>{value((v) => v.deviceTruth)}</dd></div>
      <div><dt>Last error</dt><dd>{view ? (view.lastError ? `${view.lastError.code}${view.lastError.detail ? ` · ${view.lastError.detail}` : ''}` : 'none observed') : 'UNKNOWN'}</dd></div>
      <div><dt>Last sequence</dt><dd>{value((v) => v.lastSequence ?? 'UNKNOWN')}</dd></div>
    </dl>
    <div className="runtime-controls">
      {controls.map((control) => {
        const availability = runtimeControlAvailability(control);
        return <button key={control} type="button" disabled={!availability.enabled} title={availability.reason}>{control.toUpperCase()}</button>;
      })}
      <small>{runtimeControlAvailability('start').reason}</small>
    </div>
  </section>;
}
