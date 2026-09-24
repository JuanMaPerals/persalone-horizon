import { type ChangeEvent, type ReactElement, useEffect, useRef, useState } from 'react';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';
import {
  LATENCY_STAGES,
  MIN_SAMPLES_P50,
  MIN_SAMPLES_P95,
  UNOBSERVABLE_LATENCY_STAGES,
  parseRuntimeEventStream,
  reduceRuntimeEvents,
  runtimeControlAvailability,
  type RuntimeControl,
  type RuntimeView,
} from '../runtime/runtimeEvents';

const controls: readonly RuntimeControl[] = ['start', 'stop', 'panic'];

const ms = (value: number | string): string => (typeof value === 'number' ? `${(value / 1000).toFixed(1)} ms` : value);
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
    <table className="latency-table" aria-label="Turn latency">
      <caption>Turn latency · monotonic runtime clock · p50 needs {MIN_SAMPLES_P50}+ samples, p95 needs {MIN_SAMPLES_P95}+</caption>
      <thead>
        <tr><th scope="col">Stage</th><th scope="col">Latest</th><th scope="col">p50</th><th scope="col">p95</th><th scope="col">Samples</th><th scope="col">Environment</th><th scope="col">Evidence</th></tr>
      </thead>
      <tbody>
        {LATENCY_STAGES.map((stage) => {
          const stat = view?.latency[stage];
          return <tr key={stage}>
            <th scope="row">{stage}</th>
            <td>{stat ? ms(stat.latestMicros) : 'UNKNOWN'}</td>
            <td>{stat ? ms(stat.p50Micros) : 'UNKNOWN'}</td>
            <td>{stat ? ms(stat.p95Micros) : 'UNKNOWN'}</td>
            <td>{stat ? stat.samples : 'UNKNOWN'}</td>
            <td>{stat ? stat.environment : 'UNKNOWN'}</td>
            <td>{stat ? stat.truth : 'UNKNOWN'}</td>
          </tr>;
        })}
        {UNOBSERVABLE_LATENCY_STAGES.map((stage) => <tr key={stage}>
          <th scope="row">{stage}</th>
          <td colSpan={6}>UNKNOWN · not observable on the runtime clock</td>
        </tr>)}
      </tbody>
    </table>
    <div className="runtime-controls">
      {controls.map((control) => {
        const availability = runtimeControlAvailability(control);
        return <button key={control} type="button" disabled={!availability.enabled} title={availability.reason}>{control.toUpperCase()}</button>;
      })}
      <small>{runtimeControlAvailability('start').reason}</small>
    </div>
  </section>;
}
