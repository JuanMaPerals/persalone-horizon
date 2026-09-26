// Read-only consumer of the redacted `horizon.runtime-event.v1` stream emitted
// by the G5 runtime (packages/contracts RuntimeEvent). The Console never runs
// its own runtime; it only renders what the stream proves, or UNKNOWN.

export const RUNTIME_EVENT_SCHEMA = 'horizon.runtime-event.v1';

export type ExecutionEnvironment = 'SIMULATED' | 'EMULATED' | 'PC_REAL' | 'HALO_REAL';
export type Truth = 'SIMULATED' | 'PREPARED' | 'MEASURED' | 'BLOCKED' | 'FAILED';
export type SessionState = 'idle' | 'preparing' | 'listening' | 'stopping' | 'stopped' | 'failed' | 'disposed';
export type CaptionStatus = 'delivered' | 'blocked' | 'failed';

interface EventBase {
  readonly seq: number;
  readonly atMicros: number;
  readonly session: { readonly id: string; readonly epoch: number | null } | null;
}

export interface SessionStateEvent extends EventBase {
  readonly kind: 'sessionState';
  readonly state: SessionState;
  readonly failureCode: string | null;
}

export interface CaptionEvent extends EventBase {
  readonly kind: 'caption';
  readonly turn: number | null;
  readonly status: CaptionStatus;
  readonly environment: ExecutionEnvironment;
  readonly truth: Truth;
  readonly adapter: string | null;
  readonly reason: string | null;
}

export interface DiagnosticEvent extends EventBase {
  readonly kind: 'diagnostic';
  readonly code: string;
  readonly component: string | null;
  readonly turn: number | null;
  readonly detail: string | null;
}

export type RuntimeEvent = SessionStateEvent | CaptionEvent | DiagnosticEvent;

const environments: readonly ExecutionEnvironment[] = ['SIMULATED', 'EMULATED', 'PC_REAL', 'HALO_REAL'];
const truths: readonly Truth[] = ['SIMULATED', 'PREPARED', 'MEASURED', 'BLOCKED', 'FAILED'];
const states: readonly SessionState[] = ['idle', 'preparing', 'listening', 'stopping', 'stopped', 'failed', 'disposed'];
const captionStatuses: readonly CaptionStatus[] = ['delivered', 'blocked', 'failed'];
const baseKeys = ['schema', 'seq', 'atMicros', 'kind', 'session'];
const keysByKind: Record<RuntimeEvent['kind'], readonly string[]> = {
  sessionState: [...baseKeys, 'state', 'failureCode'],
  caption: [...baseKeys, 'turn', 'status', 'environment', 'truth', 'adapter', 'reason'],
  diagnostic: [...baseKeys, 'code', 'component', 'turn', 'detail'],
};
const token = /^[A-Za-z0-9_.:-]{1,64}$/;

export class RuntimeEventError extends Error {}

function fail(reason: string): never {
  throw new RuntimeEventError(reason);
}

function int(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) fail(`${field} must be a non-negative integer`);
  return value;
}

function optionalInt(value: unknown, field: string): number | null {
  return value === null ? null : int(value, field);
}

function optionalToken(value: unknown, field: string): string | null {
  if (value === null) return null;
  if (typeof value !== 'string' || !token.test(value)) fail(`${field} must be a coded token`);
  return value;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[], field: string): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) fail(`${field} is not an allowed value`);
  return value as T;
}

/** Parses one NDJSON line strictly. Unknown schema, kind, extra fields (for example `text`) or out-of-range values are rejected. */
export function parseRuntimeEventLine(line: string): RuntimeEvent {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    fail('line is not JSON');
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) fail('event must be an object');
  const record = raw as Record<string, unknown>;
  if (record.schema !== RUNTIME_EVENT_SCHEMA) fail('unsupported schema');
  const kind = oneOf(record.kind, ['sessionState', 'caption', 'diagnostic'] as const, 'kind');
  const expected = keysByKind[kind];
  const keys = Object.keys(record);
  if (keys.length !== expected.length || keys.some((key) => !expected.includes(key))) fail(`unexpected fields for ${kind}`);

  let session: EventBase['session'] = null;
  if (record.session !== null) {
    const value = record.session as Record<string, unknown> | undefined;
    if (typeof value !== 'object' || value === null || Object.keys(value).sort().join(',') !== 'epoch,id') fail('invalid session');
    session = { id: optionalToken(value.id, 'session.id') ?? fail('session.id required'), epoch: optionalInt(value.epoch, 'session.epoch') };
  }
  const base = { seq: int(record.seq, 'seq'), atMicros: int(record.atMicros, 'atMicros'), session };

  switch (kind) {
    case 'sessionState':
      return { ...base, kind, state: oneOf(record.state, states, 'state'), failureCode: optionalToken(record.failureCode, 'failureCode') };
    case 'caption':
      return {
        ...base,
        kind,
        turn: optionalInt(record.turn, 'turn'),
        status: oneOf(record.status, captionStatuses, 'status'),
        environment: oneOf(record.environment, environments, 'environment'),
        truth: oneOf(record.truth, truths, 'truth'),
        adapter: optionalToken(record.adapter, 'adapter'),
        reason: optionalToken(record.reason, 'reason'),
      };
    case 'diagnostic':
      return {
        ...base,
        kind,
        code: optionalToken(record.code, 'code') ?? fail('code required'),
        component: optionalToken(record.component, 'component'),
        turn: optionalInt(record.turn, 'turn'),
        detail: optionalToken(record.detail, 'detail'),
      };
  }
}

export interface ParsedRuntimeStream {
  readonly events: readonly RuntimeEvent[];
  readonly rejected: readonly { readonly line: number; readonly reason: string }[];
}

export function parseRuntimeEventStream(text: string): ParsedRuntimeStream {
  const events: RuntimeEvent[] = [];
  const rejected: { line: number; reason: string }[] = [];
  text.split('\n').forEach((line, index) => {
    if (line.trim() === '') return;
    try {
      events.push(parseRuntimeEventLine(line));
    } catch (error) {
      rejected.push({ line: index + 1, reason: error instanceof RuntimeEventError ? error.message : 'invalid event' });
    }
  });
  return { events, rejected };
}

export type Known<T> = T | 'UNKNOWN';

export interface RuntimeView {
  readonly sessionId: Known<string>;
  readonly sessionState: Known<SessionState>;
  readonly failureCode: string | null;
  readonly captions: Readonly<Record<CaptionStatus, number>>;
  /** Execution path of the last caption; never inferred from anything else. */
  readonly captionEnvironment: Known<ExecutionEnvironment>;
  /** Evidence label of the last caption, kept separate from the environment. */
  readonly captionTruth: Known<Truth>;
  readonly lastError: { readonly code: string; readonly component: string | null; readonly detail: string | null } | null;
  readonly errorCount: number;
  readonly lastSequence: number | null;
  readonly sequenceGaps: number;
  readonly rejectedLines: number;
  readonly degraded: boolean;
}

const errorCodes = new Set(['captionFailed', 'captionBlocked', 'synthesisFailed', 'providerUnavailable', 'frameRejected', 'consentDenied']);

export function reduceRuntimeEvents(stream: ParsedRuntimeStream): RuntimeView {
  let sessionId: Known<string> = 'UNKNOWN';
  let sessionState: Known<SessionState> = 'UNKNOWN';
  let failureCode: string | null = null;
  const captions: Record<CaptionStatus, number> = { delivered: 0, blocked: 0, failed: 0 };
  let captionEnvironment: Known<ExecutionEnvironment> = 'UNKNOWN';
  let captionTruth: Known<Truth> = 'UNKNOWN';
  let lastError: RuntimeView['lastError'] = null;
  let errorCount = 0;
  let lastSequence: number | null = null;
  let sequenceGaps = 0;

  const ordered = [...stream.events].sort((a, b) => a.seq - b.seq);
  for (const event of ordered) {
    if (lastSequence !== null && event.seq !== lastSequence + 1) sequenceGaps += 1;
    lastSequence = event.seq;
    if (event.session) sessionId = event.session.id;
    switch (event.kind) {
      case 'sessionState':
        sessionState = event.state;
        failureCode = event.failureCode;
        break;
      case 'caption':
        captions[event.status] += 1;
        captionEnvironment = event.environment;
        captionTruth = event.truth;
        break;
      case 'diagnostic':
        if (errorCodes.has(event.code)) {
          errorCount += 1;
          lastError = { code: event.code, component: event.component, detail: event.detail };
        }
        break;
    }
  }
  return {
    sessionId,
    sessionState,
    failureCode,
    captions,
    captionEnvironment,
    captionTruth,
    lastError,
    errorCount,
    lastSequence,
    sequenceGaps,
    rejectedLines: stream.rejected.length,
    degraded: sequenceGaps > 0 || stream.rejected.length > 0,
  };
}

export type RuntimeControl = 'start' | 'stop' | 'panic';

/** Controls stay disabled until an authenticated, bounded control API exists. The event stream is read-only and never carries commands. */
export function runtimeControlAvailability(_control: RuntimeControl): { readonly enabled: false; readonly reason: string } {
  return {
    enabled: false,
    reason: 'No authenticated control API exists yet; the runtime event stream is read-only.',
  };
}
