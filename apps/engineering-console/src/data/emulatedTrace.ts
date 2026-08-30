import type { HaloTraceEvent, TraceSession } from '../types/trace';

const sessionId = 'halo-emulated-session-042';
const traceId = 'trace-halo-042';
const origin = Date.parse('2026-08-22T08:42:00.000Z');

function event(
  id: string,
  offsetMs: number,
  sequence: number,
  domain: HaloTraceEvent['domain'],
  kind: HaloTraceEvent['kind'],
  title: string,
  summary: string,
  options: Partial<Omit<HaloTraceEvent, 'id' | 'sessionId' | 'sequence' | 'occurredAt' | 'domain' | 'kind' | 'title' | 'summary'>> = {},
): HaloTraceEvent {
  return {
    id,
    sessionId,
    sequence,
    occurredAt: new Date(origin + offsetMs).toISOString(),
    domain,
    kind,
    title,
    summary,
    severity: options.severity ?? 'info',
    evidence: options.evidence ?? 'SIMULATED',
    relation: options.relation ?? {
      traceId,
      spanId: `span-${String(sequence).padStart(3, '0')}`,
      parentEventId: sequence > 1 ? `evt-${String(sequence - 1).padStart(3, '0')}` : undefined,
    },
    span: options.span,
    tags: options.tags ?? [],
    attributes: options.attributes ?? {},
    redacted: options.redacted ?? true,
  };
}

export const emulatedSessions: readonly TraceSession[] = [
  {
    id: sessionId,
    label: 'Emulated translation handshake · ES → EN',
    startedAt: new Date(origin).toISOString(),
    evidence: 'SIMULATED',
    source: 'EMULATED',
  },
];

export const emulatedTraceEvents: readonly HaloTraceEvent[] = [
  event('evt-001', 0, 1, 'session', 'session.started', 'Session initialized', 'Emulated session started with a local-only trace.', {
    tags: ['session', 'emulated'],
    attributes: { direction: 'es-EN', privacy_generation: 1 },
  }),
  event('evt-002', 160, 2, 'ble', 'ble.discovery', 'Halo fixture discovered', 'Scripted fixture exposed a declared display path.', {
    tags: ['fixture', 'ble'],
    attributes: { adapter: 'ScriptedHaloFixture', device_source: 'fixture' },
  }),
  event('evt-003', 420, 3, 'ble', 'ble.connected', 'Fixture connected', 'Single emulated connection established.', {
    tags: ['connection'],
    attributes: { mtu: 185, reconnect_attempt: 0 },
  }),
  event('evt-004', 590, 4, 'ble', 'ble.capability.blocked', 'Microphone remains blocked', 'Physical microphone capture has no measured device evidence.', {
    evidence: 'BLOCKED',
    severity: 'warn',
    tags: ['capability', 'truth-state'],
    attributes: { capability: 'microphoneCapture', reason: 'physical validation pending' },
  }),
  event('evt-005', 880, 5, 'audio', 'audio.capture.started', 'Host audio harness started', 'Prepared host capture path started; no PCM is logged.', {
    evidence: 'PREPARED',
    tags: ['host-audio', 'privacy'],
    attributes: { codec: 'pcm_s16le', sample_rate_hz: 16000, payload_logged: false },
  }),
  event('evt-006', 1230, 6, 'audio', 'audio.frame.received', 'Audio frame metadata received', 'Frame timing is retained while payload bytes remain outside the trace.', {
    evidence: 'PREPARED',
    tags: ['frame', 'redacted'],
    attributes: { sequence: 24, duration_ms: 20, discontinuity: false },
  }),
  event('evt-007', 1710, 7, 'translation', 'translation.asr.partial', 'Partial transcript boundary', 'Emulated partial marker only; transcript content is intentionally absent.', {
    tags: ['asr', 'redacted'],
    attributes: { language: 'es', content_retained: false },
  }),
  event('evt-008', 2110, 8, 'translation', 'translation.completed', 'Translation stage completed', 'Emulated segment translated through the deterministic fixture.', {
    tags: ['translation', 'emulated'],
    span: { startedAtMs: origin + 1710, endedAtMs: origin + 2110, durationMs: 400 },
    attributes: { source_language: 'es', target_language: 'en', provider: 'fixture' },
  }),
  event('evt-009', 2380, 9, 'translation', 'translation.tts.queued', 'Output queued', 'Prepared output adapter received timing metadata only.', {
    evidence: 'PREPARED',
    tags: ['tts', 'prepared'],
    attributes: { output_route: 'host-speaker', audio_payload_logged: false },
  }),
  event('evt-010', 2760, 10, 'memory', 'memory.lookup', 'Memory lookup denied', 'No memory/RAG payload is available without explicit policy and consent.', {
    evidence: 'BLOCKED',
    severity: 'warn',
    tags: ['memory', 'policy'],
    attributes: { reason: 'memory disabled by session policy' },
  }),
  event('evt-011', 2950, 11, 'policy', 'policy.redaction', 'Sensitive fields redacted', 'Console trace confirmed the redaction boundary before persistence.', {
    tags: ['privacy', 'redaction'],
    attributes: { field_count: 3, persisted_payload: false },
  }),
  event('evt-012', 3310, 12, 'audio', 'audio.capture.stopped', 'Host audio harness stopped', 'Bounded local test buffer was released.', {
    evidence: 'PREPARED',
    tags: ['host-audio', 'cleanup'],
    attributes: { frames_seen: 24, buffer_purged: true },
  }),
  event('evt-013', 3560, 13, 'session', 'session.ended', 'Session completed', 'Emulated session completed without physical-device claims.', {
    tags: ['session', 'complete'],
    attributes: { terminal_state: 'completed', physical_claim: false },
  }),
];
