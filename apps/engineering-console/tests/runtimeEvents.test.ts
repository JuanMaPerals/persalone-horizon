import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  parseRuntimeEventLine,
  parseRuntimeEventStream,
  reduceRuntimeEvents,
  RuntimeEventError,
} from '../src/runtime/runtimeEvents';

// Both fixtures are produced by the real G5 runtime
// (packages/translation_runtime/test/runtime_event_stream_test.dart) and are
// checked there for drift; they are never edited by hand.
const golden = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');

describe('runtime event stream wiring (golden from G5 runtime)', () => {
  it('reduces a stopped session with delivered and blocked captions', () => {
    const stream = parseRuntimeEventStream(golden('runtime-events.stop.v1.ndjson'));
    expect(stream.rejected).toEqual([]);
    const view = reduceRuntimeEvents(stream);
    expect(view.sessionId).toBe('session-golden');
    expect(view.sessionState).toBe('stopped');
    expect(view.captions).toEqual({ delivered: 1, blocked: 1, failed: 0 });
    expect(view.captionEnvironment).toBe('SIMULATED');
    expect(view.captionTruth).toBe('BLOCKED');
    expect(view.degraded).toBe(false);
  });

  it('reduces a failed session with a caption error and failure code', () => {
    const view = reduceRuntimeEvents(parseRuntimeEventStream(golden('runtime-events.failure.v1.ndjson')));
    expect(view.sessionState).toBe('failed');
    expect(view.failureCode).toBe('providerUnavailable');
    expect(view.captions).toEqual({ delivered: 1, blocked: 0, failed: 1 });
    expect(view.lastError?.code).toBe('captionFailed');
    expect(view.lastError?.detail).toBe('adapterError');
    expect(view.degraded).toBe(false);
  });

  it('keeps environment and evidence as distinct fields', () => {
    const view = reduceRuntimeEvents(parseRuntimeEventStream(golden('runtime-events.failure.v1.ndjson')));
    expect(view.captionEnvironment).toBe('SIMULATED');
    expect(view.captionTruth).toBe('FAILED');
  });
});

describe('degraded and hostile input', () => {
  const base = { schema: 'horizon.runtime-event.v1', seq: 1, atMicros: 1, kind: 'caption', session: { id: 's', epoch: 1 }, turn: 1, status: 'delivered', environment: 'EMULATED', truth: 'PREPARED', adapter: 'halo-caption:x', reason: null };

  it('shows UNKNOWN for everything when no stream is loaded', () => {
    const view = reduceRuntimeEvents({ events: [], rejected: [] });
    expect([view.sessionId, view.sessionState, view.captionEnvironment, view.captionTruth]).toEqual(['UNKNOWN', 'UNKNOWN', 'UNKNOWN', 'UNKNOWN']);
    expect(view.lastSequence).toBeNull();
  });

  it('rejects text-bearing, unknown-schema, malformed and out-of-range events', () => {
    for (const line of [
      JSON.stringify({ ...base, text: 'hola' }),
      JSON.stringify({ ...base, schema: 'horizon.runtime-event.v2' }),
      JSON.stringify({ ...base, environment: 'HARDWARE' }),
      JSON.stringify({ ...base, truth: 'OBSERVED' }),
      JSON.stringify({ ...base, reason: 'a sentence with spaces' }),
      JSON.stringify({ ...base, seq: -1 }),
      '{not json',
    ]) {
      expect(() => parseRuntimeEventLine(line), line).toThrow(RuntimeEventError);
    }
  });

  it('flags rejected lines and sequence gaps as DEGRADED without inventing state', () => {
    const text = [
      JSON.stringify(base),
      '{broken',
      JSON.stringify({ ...base, seq: 4, environment: 'HALO_REAL', truth: 'PREPARED' }),
    ].join('\n');
    const view = reduceRuntimeEvents(parseRuntimeEventStream(text));
    expect(view.rejectedLines).toBe(1);
    expect(view.sequenceGaps).toBe(1);
    expect(view.degraded).toBe(true);
    expect(view.sessionState).toBe('UNKNOWN');
    expect(view.captionEnvironment).toBe('HALO_REAL');
    expect(view.captionTruth).toBe('PREPARED');
  });

  it('never reports HALO_REAL unless an event says so', () => {
    const view = reduceRuntimeEvents(parseRuntimeEventStream(JSON.stringify(base)));
    expect(view.captionEnvironment).toBe('EMULATED');
  });
});
