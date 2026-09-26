import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  MAX_LATENCY_MICROS,
  MIN_SAMPLES_P50,
  MIN_SAMPLES_P95,
  parseRuntimeEventLine,
  parseRuntimeEventStream,
  percentile,
  reduceRuntimeEvents,
  RuntimeEventError,
} from '../src/runtime/runtimeEvents';

// The latency fixture is produced by the real G5 runtime
// (runtime_event_stream_test.dart, 24 turns, turn 7 caption blocked).
const golden = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');

const sample = (seq: number, micros: number, extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    schema: 'horizon.runtime-event.v1',
    seq,
    atMicros: seq,
    kind: 'latency',
    session: { id: 's', epoch: 1 },
    turn: seq,
    stage: 'finalToCaption',
    micros,
    environment: 'EMULATED',
    truth: 'MEASURED',
    ...extra,
  });

const streamOf = (values: readonly number[], extra: (i: number) => Record<string, unknown> = () => ({})) =>
  parseRuntimeEventStream(values.map((v, i) => sample(i + 1, v, extra(i))).join('\n'));

describe('latency from the G5 runtime golden', () => {
  it('reports every measured stage with sample counts, environment and evidence', () => {
    const stream = parseRuntimeEventStream(golden('runtime-events.latency.v1.ndjson'));
    expect(stream.rejected).toEqual([]);
    const { latency } = reduceRuntimeEvents(stream);
    expect(latency.finalToTranslation.samples).toBe(24);
    expect(latency.finalToSpeechQueued.samples).toBe(24);
    expect(latency.finalToCaption.samples).toBe(23);
    expect(latency.finalToCaption.environment).toBe('SIMULATED');
    expect(latency.finalToCaption.truth).toBe('MEASURED');
    expect(typeof latency.finalToCaption.p95Micros).toBe('number');
    // The runtime cannot know where the translator ran.
    expect(latency.finalToTranslation.environment).toBe('UNKNOWN');
  });

  it('audible-output stages stay UNKNOWN until the device measured them', () => {
    const { latency } = reduceRuntimeEvents(parseRuntimeEventStream(golden('runtime-events.latency.v1.ndjson')));
    expect(latency.speechQueuedToAudible).toMatchObject({ samples: 0, p50Micros: 'UNKNOWN', truth: 'UNKNOWN' });
    expect(latency.speechEndToAudible).toMatchObject({ samples: 0, p50Micros: 'UNKNOWN', truth: 'UNKNOWN' });
  });

  it('measured audible-output samples are accepted without an environment', () => {
    const lines = [1, 2].map((seq) => sample(seq, 400_000 + seq, { stage: 'speechQueuedToAudible', environment: null }));
    const stream = parseRuntimeEventStream([...lines, sample(3, 2_000_000, { stage: 'speechEndToAudible', environment: null })].join('\n'));
    expect(stream.rejected).toEqual([]);
    const { latency } = reduceRuntimeEvents(stream);
    expect(latency.speechQueuedToAudible).toMatchObject({ samples: 2, latestMicros: 400_002, p50Micros: 'INSUFFICIENT', environment: 'UNKNOWN', truth: 'MEASURED' });
    expect(latency.speechEndToAudible.samples).toBe(1);
  });

  it('older goldens still parse and carry latency lines', () => {
    for (const name of ['runtime-events.stop.v1.ndjson', 'runtime-events.failure.v1.ndjson']) {
      const stream = parseRuntimeEventStream(golden(name));
      expect(stream.rejected, name).toEqual([]);
      expect(stream.events.some((e) => e.kind === 'latency'), name).toBe(true);
    }
  });
});

describe('latency statistics', () => {
  it('is UNKNOWN with no samples, never zero', () => {
    const { latency } = reduceRuntimeEvents({ events: [], rejected: [] });
    for (const stat of Object.values(latency)) {
      expect(stat).toEqual({ samples: 0, latestMicros: 'UNKNOWN', p50Micros: 'UNKNOWN', p95Micros: 'UNKNOWN', environment: 'UNKNOWN', truth: 'UNKNOWN' });
    }
  });

  it('shows percentiles only with enough samples', () => {
    const few = reduceRuntimeEvents(streamOf(Array.from({ length: MIN_SAMPLES_P50 - 1 }, () => 1000))).latency.finalToCaption;
    expect(few.p50Micros).toBe('INSUFFICIENT');
    expect(few.p95Micros).toBe('INSUFFICIENT');
    expect(few.latestMicros).toBe(1000);

    const some = reduceRuntimeEvents(streamOf(Array.from({ length: MIN_SAMPLES_P50 }, (_, i) => (i + 1) * 1000))).latency.finalToCaption;
    expect(some.p50Micros).toBe(3000);
    expect(some.p95Micros).toBe('INSUFFICIENT');

    const many = reduceRuntimeEvents(streamOf(Array.from({ length: MIN_SAMPLES_P95 }, (_, i) => (i + 1) * 1000))).latency.finalToCaption;
    expect(many.p50Micros).toBe(10000);
    expect(many.p95Micros).toBe(19000);
  });

  it('latest follows stream order, not arrival order', () => {
    const lines = [sample(2, 7000), sample(1, 3000)].join('\n');
    expect(reduceRuntimeEvents(parseRuntimeEventStream(lines)).latency.finalToCaption.latestMicros).toBe(7000);
  });

  it('nearest-rank percentile', () => {
    expect(percentile([5], 95)).toBe(5);
    expect(percentile([1, 2, 3, 4], 50)).toBe(2);
    expect(percentile(Array.from({ length: 100 }, (_, i) => i + 1), 95)).toBe(95);
  });

  it('never merges environments silently', () => {
    const view = reduceRuntimeEvents(streamOf([1000, 2000], (i) => ({ environment: i === 0 ? 'EMULATED' : 'HALO_REAL' })));
    expect(view.latency.finalToCaption.environment).toBe('MIXED');
  });
});

describe('hostile latency events are rejected', () => {
  it.each([
    ['text field', { text: 'hola' }],
    ['non-MEASURED evidence', { truth: 'PREPARED' }],
    ['simulated evidence', { truth: 'SIMULATED' }],
    ['unknown stage', { stage: 'speechQueuedToHeard' }],
    ['negative interval', { micros: -1 }],
    ['fractional interval', { micros: 1.5 }],
    ['absurd interval', { micros: MAX_LATENCY_MICROS + 1 }],
    ['missing turn', { turn: null }],
    ['fake environment', { environment: 'HARDWARE' }],
  ])('%s', (_name, extra) => {
    expect(() => parseRuntimeEventLine(sample(1, 1000, extra))).toThrow(RuntimeEventError);
  });

  it('a rejected latency line degrades the view instead of skewing percentiles', () => {
    const text = [sample(1, 1000), sample(2, 1000, { truth: 'PREPARED' })].join('\n');
    const view = reduceRuntimeEvents(parseRuntimeEventStream(text));
    expect(view.degraded).toBe(true);
    expect(view.latency.finalToCaption.samples).toBe(1);
  });
});

describe('physical validation signals (golden from G5 runtime)', () => {
  const view = () => reduceRuntimeEvents(parseRuntimeEventStream(golden('runtime-events.validation.v1.ndjson')));

  it('parses without rejection and measures end of speech to final', () => {
    const stream = parseRuntimeEventStream(golden('runtime-events.validation.v1.ndjson'));
    expect(stream.rejected).toEqual([]);
    const stat = view().latency.speechEndToFinal;
    expect(stat.samples).toBe(2);
    expect(stat.latestMicros).toBe(500);
    expect(stat.truth).toBe('MEASURED');
  });

  it('counts self-echo suspicion, with and without text overlap', () => {
    expect(view().selfEcho).toEqual({ suspected: 1, withTextOverlap: 1 });
  });

  it('reports glyph degradation as a limit, not as Unicode support', () => {
    expect(view().captionGlyphs).toEqual({ folded: 0, replaced: 2 });
  });

  it('no validation signals means zero, never inferred', () => {
    const empty = reduceRuntimeEvents({ events: [], rejected: [] });
    expect(empty.selfEcho).toEqual({ suspected: 0, withTextOverlap: 0 });
    expect(empty.captionGlyphs).toEqual({ folded: 0, replaced: 0 });
    expect(empty.latency.speechEndToFinal.latestMicros).toBe('UNKNOWN');
  });
});
