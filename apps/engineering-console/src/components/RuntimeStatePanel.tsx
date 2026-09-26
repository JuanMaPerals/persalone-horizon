import { type ChangeEvent, type ReactElement, useState } from 'react';
import {
  parseRuntimeEventStream,
  reduceRuntimeEvents,
  runtimeControlAvailability,
  type RuntimeControl,
  type RuntimeView,
} from '../runtime/runtimeEvents';

const controls: readonly RuntimeControl[] = ['start', 'stop', 'panic'];

export function RuntimeStatePanel(): ReactElement {
  const [view, setView] = useState<RuntimeView | null>(null);
  const [sourceName, setSourceName] = useState<string | null>(null);

  const load = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;
    setSourceName(file.name);
    setView(reduceRuntimeEvents(parseRuntimeEventStream(await file.text())));
  };

  const value = <T,>(read: (v: RuntimeView) => T): T | 'UNKNOWN' => (view ? read(view) : 'UNKNOWN');

  return <section className="monitor-panel">
    <div className="monitor-status">
      <span className="status-led" />
      {sourceName ? `Runtime event stream: ${sourceName}` : 'No runtime event stream loaded — all state UNKNOWN'}
    </div>
    <label className="runtime-source">
      <span>Load horizon.runtime-event.v1 (.ndjson, read-only)</span>
      <input type="file" accept=".ndjson,application/x-ndjson" onChange={(event) => void load(event)} />
    </label>
    {view?.degraded ? <p role="alert">DEGRADED: {view.rejectedLines} rejected line(s), {view.sequenceGaps} sequence gap(s).</p> : null}
    <dl className="metric-list">
      <div><dt>Session</dt><dd>{value((v) => v.sessionId)}</dd></div>
      <div><dt>State</dt><dd>{value((v) => v.sessionState)}{view?.failureCode ? ` (${view.failureCode})` : ''}</dd></div>
      <div><dt>Caption environment</dt><dd>{value((v) => v.captionEnvironment)}</dd></div>
      <div><dt>Caption evidence</dt><dd>{value((v) => v.captionTruth)}</dd></div>
      <div><dt>Captions delivered / blocked / failed</dt><dd>{view ? `${view.captions.delivered} / ${view.captions.blocked} / ${view.captions.failed}` : 'UNKNOWN'}</dd></div>
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
