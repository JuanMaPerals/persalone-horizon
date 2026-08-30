import { Background, Controls, MiniMap, ReactFlow, type Edge, type Node } from '@xyflow/react';
import { type ReactElement, useEffect, useMemo } from 'react';
import { isSensitiveAttribute, type HaloTraceEvent } from '../types/trace';
import { useTraceSnapshot, useTraceStore } from '../store/TraceStoreContext';

export type ConsolePanelId =
  | 'execution-graph'
  | 'timeline'
  | 'inspector'
  | 'logs'
  | 'ble-monitor'
  | 'translation'
  | 'memory-rag'
  | 'metrics';

interface ConsolePanelProps {
  readonly panelId: ConsolePanelId;
}

const domainColor: Record<HaloTraceEvent['domain'], string> = {
  session: '#8b8fae',
  ble: '#4f9cff',
  audio: '#22c55e',
  translation: '#c084fc',
  memory: '#f59e0b',
  policy: '#fb7185',
  agent: '#38bdf8',
};

function EvidencePill({ value }: { readonly value: HaloTraceEvent['evidence'] }): ReactElement {
  return <span className={`evidence evidence-${value.toLowerCase()}`}>{value}</span>;
}

function formatTime(value: string): string {
  return new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 3,
  }).format(new Date(value));
}

function formatElapsed(position: number, start: number): string {
  return `${((position - start) / 1000).toFixed(2)}s`;
}

function EmptyState({ children }: { readonly children: string }): ReactElement {
  return <div className="empty-state">{children}</div>;
}

function ExecutionGraph(): ReactElement {
  const store = useTraceStore();
  const snapshot = useTraceSnapshot();
  const events = store.visibleEvents();
  const { nodes, edges } = useMemo(() => {
    const nodeWidth = 185;
    const nodes: Node[] = events.map((event, index) => ({
      id: event.id,
      position: { x: (index % 4) * 235, y: Math.floor(index / 4) * 126 },
      data: { label: `${event.sequence.toString().padStart(2, '0')} · ${event.title}` },
      style: {
        background: '#141824', border: `1px solid ${domainColor[event.domain]}`,
        borderRadius: 6, color: '#e6e8ef', fontSize: 12, padding: 10, width: nodeWidth,
        boxShadow: snapshot.focus?.type === 'graph-node' && snapshot.focus.eventId === event.id
          ? `0 0 0 2px ${domainColor[event.domain]}` : undefined,
      },
    }));
    const eventIds = new Set(events.map((event) => event.id));
    const edges: Edge[] = events.flatMap((event) => {
      const source = event.relation.parentEventId ?? event.relation.causeEventId;
      return source && eventIds.has(source) ? [{
        id: `${source}-${event.id}`, source, target: event.id, animated: event.severity === 'warn',
        style: { stroke: domainColor[event.domain], strokeWidth: 1.4 },
      }] : [];
    });
    return { nodes, edges };
  }, [events, snapshot.focus]);

  if (events.length === 0) return <EmptyState>No trace events match the current filters.</EmptyState>;
  return (
    <div className="graph-panel">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        fitView
        minZoom={0.3}
        onNodeClick={(_, node) => store.setFocus({ type: 'graph-node', eventId: node.id })}
      >
        <Background color="#242b3d" gap={20} size={1} />
        <Controls showInteractive={false} />
        <MiniMap nodeColor={(node) => String(node.style?.borderColor ?? '#4f9cff')} maskColor="rgba(6, 8, 14, 0.7)" />
      </ReactFlow>
    </div>
  );
}

function Timeline(): ReactElement {
  const store = useTraceStore();
  const snapshot = useTraceSnapshot();
  const events = store.visibleEvents();
  const range = store.timelineRange();
  useEffect(() => {
    if (!snapshot.replay.active) return undefined;
    const timer = window.setInterval(() => {
      const next = snapshot.replay.positionMs + 80 * snapshot.replay.speed;
      if (next >= range.end) {
        store.seek(range.end);
        store.setReplay(false);
        return;
      }
      store.seek(next);
    }, 80);
    return () => window.clearInterval(timer);
  }, [range.end, snapshot.replay.active, snapshot.replay.positionMs, snapshot.replay.speed, store]);

  if (events.length === 0) return <EmptyState>No timeline data is available.</EmptyState>;
  const span = Math.max(range.end - range.start, 1);
  return (
    <section className="timeline-panel">
      <div className="replay-toolbar">
        <button type="button" className="icon-button" onClick={() => {
          if (snapshot.replay.active) {
            store.setReplay(false);
            return;
          }
          if (snapshot.replay.positionMs >= range.end) store.seek(range.start);
          store.setReplay(true);
        }} aria-label={snapshot.replay.active ? 'Pause replay' : 'Start replay'}>
          {snapshot.replay.active ? 'Ⅱ' : '▶'}
        </button>
        <label className="replay-label">Replay <strong>{formatElapsed(snapshot.replay.positionMs, range.start)}</strong></label>
        <input
          aria-label="Replay position"
          type="range"
          min={range.start}
          max={range.end}
          value={snapshot.replay.positionMs}
          onChange={(event) => store.seek(Number(event.target.value))}
        />
        <select aria-label="Replay speed" value={snapshot.replay.speed} onChange={(event) => store.setReplaySpeed(Number(event.target.value) as 0.5 | 1 | 2)}>
          <option value={0.5}>0.5×</option><option value={1}>1×</option><option value={2}>2×</option>
        </select>
      </div>
      <div className="timeline-track" role="list" aria-label="Trace event timeline">
        {events.map((event) => {
          const position = ((Date.parse(event.occurredAt) - range.start) / span) * 100;
          const isFocused = snapshot.focus?.type === 'event' && snapshot.focus.eventId === event.id;
          return (
            <button
              key={event.id}
              type="button"
              role="listitem"
              className={`timeline-event ${isFocused ? 'is-focused' : ''}`}
              style={{ left: `${position}%`, borderColor: domainColor[event.domain] }}
              onClick={() => store.setFocus({ type: 'event', eventId: event.id })}
              title={`${formatTime(event.occurredAt)} · ${event.title}`}
            >
              <span className="timeline-dot" style={{ background: domainColor[event.domain] }} />
              <span className="timeline-label">{event.sequence}</span>
            </button>
          );
        })}
      </div>
      <ol className="timeline-list">
        {events.map((event) => (
          <li key={event.id}>
            <button type="button" onClick={() => store.setFocus({ type: 'event', eventId: event.id })}>
              <time>{formatTime(event.occurredAt)}</time><span className="domain-dot" style={{ background: domainColor[event.domain] }} />
              <span>{event.title}</span><EvidencePill value={event.evidence} />
            </button>
          </li>
        ))}
      </ol>
    </section>
  );
}

function Inspector(): ReactElement {
  const store = useTraceStore();
  useTraceSnapshot();
  const event = store.selectedEvent();
  if (!event) return <EmptyState>Select a graph node, log record, or timeline event.</EmptyState>;
  return (
    <section className="inspector-panel">
      <div className="inspector-heading"><div><span className="eyebrow">{event.domain} / {event.kind}</span><h2>{event.title}</h2></div><EvidencePill value={event.evidence} /></div>
      <p>{event.summary}</p>
      <dl className="inspector-grid">
        <div><dt>Event ID</dt><dd>{event.id}</dd></div>
        <div><dt>Occurred</dt><dd>{formatTime(event.occurredAt)}</dd></div>
        <div><dt>Severity</dt><dd className={`severity-${event.severity}`}>{event.severity}</dd></div>
        <div><dt>Trace / span</dt><dd>{event.relation.traceId} / {event.relation.spanId}</dd></div>
      </dl>
      <h3>Attributes</h3>
      <div className="attribute-table">
        {Object.entries(event.attributes).map(([key, value]) => <div key={key}><span>{key}</span><code>{isSensitiveAttribute(key) ? '[REDACTED]' : String(value)}</code></div>)}
      </div>
      <p className="privacy-note">{event.redacted ? 'Payload boundary applied: the trace contains metadata only.' : 'Review policy scope before persisting this event.'}</p>
    </section>
  );
}

function Logs(): ReactElement {
  const store = useTraceStore();
  const snapshot = useTraceSnapshot();
  const events = store.visibleEvents();
  return (
    <section className="log-panel" aria-label="Trace logs">
      <div className="log-filter-row">
        <input value={snapshot.filters.text} onChange={(event) => store.setSearch(event.target.value)} placeholder="Filter events, domains, tags…" aria-label="Filter trace logs" />
        <span>{events.length} events</span>
      </div>
      <div className="log-table" role="table" aria-label="Normalized trace events">
        {events.map((event) => <button className={`log-row severity-${event.severity}`} key={event.id} type="button" role="row" onClick={() => store.setFocus({ type: 'event', eventId: event.id })}>
          <time>{formatTime(event.occurredAt)}</time><span>{event.domain}</span><span>{event.kind}</span><strong>{event.title}</strong><EvidencePill value={event.evidence} />
        </button>)}
      </div>
    </section>
  );
}

function BleMonitor(): ReactElement {
  const store = useTraceStore();
  useTraceSnapshot();
  const events = store.visibleEvents().filter((event) => event.domain === 'ble');
  const connected = events.some((event) => event.kind === 'ble.connected');
  return <section className="monitor-panel"><div className="monitor-status"><span className={connected ? 'status-led is-emulated' : 'status-led'} />{connected ? 'Emulated fixture connected' : 'No device connection'}</div><dl className="metric-list"><div><dt>Transport owner</dt><dd>ScriptedHaloFixture</dd></div><div><dt>Physical evidence</dt><dd><EvidencePill value="BLOCKED" /></dd></div><div><dt>Observed BLE events</dt><dd>{events.length}</dd></div></dl><p>BLE trace is a deterministic fixture. It is not a hardware connectivity claim.</p></section>;
}

function TranslationInspector(): ReactElement {
  const store = useTraceStore();
  useTraceSnapshot();
  const events = store.visibleEvents().filter((event) => event.domain === 'translation' || event.domain === 'audio');
  return <section className="translation-panel"><div className="translation-route"><span>ES</span><i>→</i><span>ASR</span><i>→</i><span>MT</span><i>→</i><span>EN</span><i>→</i><span>TTS</span></div>{events.map((event) => <article key={event.id}><header><span>{event.kind}</span><EvidencePill value={event.evidence} /></header><p>{event.summary}</p></article>)}</section>;
}

function MemoryRag(): ReactElement {
  const store = useTraceStore();
  useTraceSnapshot();
  const events = store.visibleEvents().filter((event) => event.domain === 'memory' || event.domain === 'policy');
  return <section className="memory-panel"><div className="guardrail"><span>Policy boundary</span><strong>Memory disabled by default</strong><p>Raw audio, unredacted transcript, identifiers, and credentials cannot enter this panel.</p></div>{events.map((event) => <article key={event.id}><EvidencePill value={event.evidence} /><h3>{event.title}</h3><p>{event.summary}</p></article>)}</section>;
}

function Metrics(): ReactElement {
  const store = useTraceStore();
  useTraceSnapshot();
  const events = store.visibleEvents();
  const range = store.timelineRange();
  const duration = Math.max(range.end - range.start, 0);
  const warnings = events.filter((event) => event.severity === 'warn' || event.severity === 'error').length;
  const prepared = events.filter((event) => event.evidence === 'PREPARED').length;
  return <section className="metrics-panel"><div><span>Trace duration</span><strong>{(duration / 1000).toFixed(2)}s</strong></div><div><span>Events</span><strong>{events.length}</strong></div><div><span>Prepared paths</span><strong>{prepared}</strong></div><div><span>Blocked / warning</span><strong>{warnings}</strong></div><p>Latency and transport data are trace-derived fixtures until a physical test run supplies signed evidence.</p></section>;
}

export function ConsolePanel({ panelId }: ConsolePanelProps): ReactElement {
  switch (panelId) {
    case 'execution-graph': return <ExecutionGraph />;
    case 'timeline': return <Timeline />;
    case 'inspector': return <Inspector />;
    case 'logs': return <Logs />;
    case 'ble-monitor': return <BleMonitor />;
    case 'translation': return <TranslationInspector />;
    case 'memory-rag': return <MemoryRag />;
    case 'metrics': return <Metrics />;
  }
}
