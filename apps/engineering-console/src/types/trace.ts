export type EvidenceState = 'SIMULATED' | 'PREPARED' | 'MEASURED' | 'BLOCKED' | 'FAILED';

export type TraceDomain =
  | 'session'
  | 'ble'
  | 'audio'
  | 'translation'
  | 'memory'
  | 'policy'
  | 'agent';

export type TraceSeverity = 'debug' | 'info' | 'warn' | 'error';

export type TraceKind =
  | 'session.started'
  | 'session.ended'
  | 'ble.discovery'
  | 'ble.connected'
  | 'ble.capability.blocked'
  | 'audio.capture.started'
  | 'audio.frame.received'
  | 'audio.capture.stopped'
  | 'translation.asr.partial'
  | 'translation.completed'
  | 'translation.tts.queued'
  | 'playback.completed'
  | 'memory.lookup'
  | 'policy.redaction'
  | 'replay.position';

export interface TraceSpan {
  readonly startedAtMs: number;
  readonly endedAtMs?: number;
  readonly durationMs?: number;
}

export interface TraceRelation {
  readonly causeEventId?: string;
  readonly parentEventId?: string;
  readonly traceId: string;
  readonly spanId: string;
}

export interface HaloTraceEvent {
  readonly id: string;
  readonly sessionId: string;
  readonly sequence: number;
  readonly occurredAt: string;
  readonly domain: TraceDomain;
  readonly kind: TraceKind;
  readonly severity: TraceSeverity;
  readonly evidence: EvidenceState;
  readonly title: string;
  readonly summary: string;
  readonly relation: TraceRelation;
  readonly span?: TraceSpan;
  readonly tags: readonly string[];
  readonly attributes: Readonly<Record<string, string | number | boolean | null>>;
  readonly redacted: boolean;
}

export type FocusTarget =
  | { readonly type: 'event'; readonly eventId: string }
  | { readonly type: 'session'; readonly sessionId: string }
  | { readonly type: 'graph-node'; readonly eventId: string }
  | { readonly type: 'timeline-position'; readonly sessionId: string; readonly positionMs: number };

export interface TraceSession {
  readonly id: string;
  readonly label: string;
  readonly startedAt: string;
  readonly evidence: EvidenceState;
  readonly source: 'EMULATED' | 'DEVICE';
}

export interface TraceFilters {
  readonly text: string;
  readonly domains: ReadonlySet<TraceDomain>;
  readonly severities: ReadonlySet<TraceSeverity>;
}

export interface ReplayState {
  readonly active: boolean;
  readonly positionMs: number;
  readonly speed: 0.5 | 1 | 2;
}

export const evidenceRank: Record<EvidenceState, number> = {
  SIMULATED: 0,
  PREPARED: 1,
  MEASURED: 2,
  BLOCKED: 3,
  FAILED: 4,
};

export function eventTimeMs(event: HaloTraceEvent): number {
  return Date.parse(event.occurredAt);
}

export function isSensitiveAttribute(key: string): boolean {
  return /audio|pcm|transcript|token|secret|key|identifier|uuid|mac/i.test(key);
}
