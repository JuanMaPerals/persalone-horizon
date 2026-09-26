import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { parseRuntimeEventLine, type RuntimeEvent } from '../src/runtime/runtimeEvents';
import { TWIN_COMPONENTS, findComponent, provenanceViolations } from '../src/twin/components';
import { TwinAssetError, fetchTwinAsset, parseManifest, toScene, validateGlb } from '../src/twin/assetLoader';
import { SEGMENTS, mapTwinState } from '../src/twin/twinStateMapper';

// Events in the exact wire format the Companion and the G5 runtime emit.
let seq = 0;
const base = (kind: string, session: string | null = 'r-000000000001', epoch = 1) => ({
  schema: 'horizon.runtime-event.v1', seq: ++seq, atMicros: seq, kind, session: session ? { id: session, epoch } : null,
});
const ev = (o: Record<string, unknown>): RuntimeEvent => parseRuntimeEventLine(JSON.stringify(o));
const session = (state: string, id = 'r-000000000001') => ev({ ...base('sessionState', id), state, failureCode: null });
const device = (state: string, environment = 'EMULATED', truth = 'PREPARED') =>
  ev({ ...base('deviceState', null), state, adapter: 'halo-device-adapter', environment, truth });
const caption = (status = 'delivered', environment = 'EMULATED', reason: string | null = null, id = 'r-000000000001') =>
  ev({ ...base('caption', id), turn: seq, status, environment, truth: status === 'delivered' ? 'PREPARED' : 'BLOCKED', adapter: 'halo-caption:x', reason });
const diag = (code: string, detail: string | null = null, component = 'runtime', id: string | null = 'r-000000000001') =>
  ev({ ...base('diagnostic', id), code, component, turn: null, detail });

const helloHaloRun = (): RuntimeEvent[] => [
  session('preparing'), device('connecting'), device('ready'), caption(), session('listening'),
  diag('inputButton', 'single', 'halo-button'), caption(),
];

describe('twin component catalogue', () => {
  it('only the official STL is OFFICIAL_GEOMETRY; inferred parts say so', () => {
    expect(provenanceViolations()).toEqual([]);
    expect(TWIN_COMPONENTS.filter((c) => c.provenance === 'OFFICIAL_GEOMETRY').map((c) => c.id)).toEqual(['shell']);
    expect(findComponent('imu')?.provenance).toBe('INFERRED_PROXY');
    expect(findComponent('button')?.provenance).toBe('OFFICIAL_LOCATION');
  });

  it('flags a proxy wrongly promoted to official geometry', () => {
    const bad = TWIN_COMPONENTS.map((c) => (c.id === 'imu' ? { ...c, provenance: 'OFFICIAL_GEOMETRY' as const } : c));
    expect(provenanceViolations(bad)).toContain('imu: proxy marked OFFICIAL_GEOMETRY');
  });

  it('every documented source points at the pinned docs commit', () => {
    for (const c of TWIN_COMPONENTS) expect(c.source, c.id).toContain('brilliantlabsAR/docs@808d317');
  });

  it('unknown components are not found', () => {
    expect(findComponent('flux-capacitor')).toBeUndefined();
  });
});

describe('TwinStateMapper', () => {
  it('outside LIVE everything is UNKNOWN and inactive, never the last green state', () => {
    for (const connection of ['IDLE', 'CONNECTING', 'DISCONNECTED', 'UNAVAILABLE', 'UNSUPPORTED'] as const) {
      const twin = mapTwinState(connection, helloHaloRun());
      expect(twin.live).toBe(false);
      for (const c of Object.values(twin.components)) expect(c).toMatchObject({ environment: 'UNKNOWN', evidence: 'UNKNOWN', activity: 'unknown' });
      for (const s of Object.values(twin.segments)) expect(s.active).toBe(false);
    }
  });

  it('Hello Halo run: display EMULATED, button pressed, link ready, only CAPTION->DISPLAY lit', () => {
    const twin = mapTwinState('LIVE', helloHaloRun());
    expect(twin.sessionState).toBe('listening');
    expect(twin.components.display).toMatchObject({ environment: 'EMULATED', evidence: 'PREPARED', activity: 'showingCaption' });
    expect(twin.components.button).toMatchObject({ environment: 'EMULATED', activity: 'lastGesture', detail: 'single' });
    expect(twin.components.mcu).toMatchObject({ environment: 'EMULATED', activity: 'connected' });
    expect(twin.components.micLeft.activity).toBe('notExercised');
    expect(twin.components.batteryLeft).toMatchObject({ environment: 'UNKNOWN', evidence: 'UNKNOWN' });
    expect(SEGMENTS.filter((s) => twin.segments[s].active)).toEqual(['CAPTION_DISPLAY']);
    expect(twin.captionSeq).not.toBeNull();
  });

  it('Panic and stop turn every path off and clear the display', () => {
    for (const end of [() => [diag('panicExecuted', null, 'companion', null)], () => [session('stopping'), session('stopped')]]) {
      const run = helloHaloRun();
      const twin = mapTwinState('LIVE', [...run, ...end()]);
      expect(SEGMENTS.filter((s) => twin.segments[s].active)).toEqual([]);
    }
    const stopped = mapTwinState('LIVE', [...helloHaloRun(), session('stopping'), session('stopped'), device('disconnected')]);
    expect(stopped.components.display.activity).toBe('cleared');
    expect(stopped.components.mcu.activity).toBe('disconnected');
  });

  it('G5 translation: segments light only with their own evidence, TTS turns off on completion', () => {
    const events = [session('preparing'), session('listening'), diag('transcriptFinal', null, 'stt')];
    expect(SEGMENTS.filter((s) => mapTwinState('LIVE', events).segments[s].active)).toEqual(['MIC_STT']);
    events.push(diag('translationCompleted', null, 'translation'), caption(), diag('synthesisStarted', null, 'tts'));
    expect(SEGMENTS.filter((s) => mapTwinState('LIVE', events).segments[s].active)).toEqual([...SEGMENTS]);
    events.push(diag('synthesisCompleted', null, 'tts'));
    expect(mapTwinState('LIVE', events).segments.TTS_SPEAKER.active).toBe(false);
    // G5 uses the phone microphone: the Halo mics are not claimed.
    expect(mapTwinState('LIVE', events).components.micLeft.activity).toBe('notExercised');
  });

  it('a blocked caption marks the display BLOCKED and does not light the path', () => {
    const twin = mapTwinState('LIVE', [session('preparing'), session('listening'), caption('blocked', 'HALO_REAL', 'capabilityUnavailable')]);
    expect(twin.components.display).toMatchObject({ environment: 'BLOCKED', activity: 'blocked' });
    expect(twin.segments.CAPTION_DISPLAY.active).toBe(false);
  });

  it('events of an older session never light the new one', () => {
    const twin = mapTwinState('LIVE', [...helloHaloRun(), session('preparing', 'r-000000000002'), session('listening', 'r-000000000002'), caption('delivered', 'EMULATED', null, 'r-000000000001')]);
    expect(twin.sessionId).toBe('r-000000000002');
    expect(twin.segments.CAPTION_DISPLAY.active).toBe(false);
  });

  it('a replayed older session never leaks its button press or caption into the new one', () => {
    const earlier = [...helloHaloRun(), session('stopping'), session('stopped')];
    const next = [session('preparing', 'r-000000000002'), device('ready'), session('listening', 'r-000000000002')];
    const twin = mapTwinState('LIVE', [...earlier, ...next]);
    expect(twin.components.button).toMatchObject({ activity: 'noPress', detail: null });
    expect(twin.components.display.activity).toBe('notExercised');
    expect(twin.components.mcu.activity).toBe('connected');
  });

  it('diagnostics that map to no component are counted, not invented', () => {
    const twin = mapTwinState('LIVE', [session('listening'), diag('somethingNew', null, 'flux')]);
    expect(twin.unmapped).toBe(1);
  });

  it('HALO_REAL never appears unless an event declares it', () => {
    const twin = mapTwinState('LIVE', helloHaloRun());
    expect(Object.values(twin.components).map((c) => c.environment)).not.toContain('HALO_REAL');
  });
});

// Minimal GLB builder for hostile-input tests.
function glb(json: Record<string, unknown>): ArrayBuffer {
  let text = JSON.stringify(json);
  while (text.length % 4) text += ' ';
  const body = new TextEncoder().encode(text);
  const out = new ArrayBuffer(20 + body.length);
  const v = new DataView(out);
  v.setUint32(0, 0x46546c67, true); v.setUint32(4, 2, true); v.setUint32(8, out.byteLength, true);
  v.setUint32(12, body.length, true); v.setUint32(16, 0x4e4f534a, true);
  new Uint8Array(out, 20).set(body);
  return out;
}

describe('twin asset validation (untrusted input)', () => {
  const official = readFileSync(new URL('../public/twin/halo.glb', import.meta.url));
  const manifestJson = JSON.parse(readFileSync(new URL('../public/twin/halo.asset.json', import.meta.url), 'utf8'));

  it('accepts the pipeline output and its manifest', () => {
    const buf = official.buffer.slice(official.byteOffset, official.byteOffset + official.byteLength);
    expect(validateGlb(buf)).toMatchObject({ asset: { version: '2.0' } });
    const m = parseManifest(manifestJson);
    expect(createHash('sha256').update(official).digest('hex')).toBe(m.sha256);
    expect(m.source.sha256).toBe('cb5aef98a7b37e4b97eb4a95e6b5d8837ab287e33a97fd97569d0f19420b78f4');
    expect(m.source.license).toBe('ISC');
    expect(m.geometry.triangles).toBeLessThan(m.geometry.inputTriangles);
  });

  it.each([
    ['not a GLB', new TextEncoder().encode('solid ascii stl').buffer, 'assetMalformed'],
    ['wrong version', (() => { const b = glb({ asset: { version: '2.0' } }); new DataView(b).setUint32(4, 1, true); return b; })(), 'assetMalformed'],
    ['truncated', glb({ asset: { version: '2.0' } }).slice(0, 30), 'assetMalformed'],
    ['external buffer URI', glb({ asset: { version: '2.0' }, buffers: [{ uri: 'https://evil.example/x.bin', byteLength: 4 }] }), 'assetExternalUri'],
    ['data URI', glb({ asset: { version: '2.0' }, buffers: [{ uri: 'data:application/octet-stream;base64,AAAA', byteLength: 3 }] }), 'assetExternalUri'],
    ['embedded image', glb({ asset: { version: '2.0' }, images: [{ bufferView: 0, mimeType: 'image/png' }] }), 'assetHasImages'],
    ['unknown extension', glb({ asset: { version: '2.0' }, extensionsUsed: ['KHR_draco_mesh_compression'] }), 'assetExtensionNotAllowed'],
  ])('%s is rejected', (_name, buffer, code) => {
    expect(() => validateGlb(buffer as ArrayBuffer)).toThrow(TwinAssetError);
    try { validateGlb(buffer as ArrayBuffer); } catch (e) { expect((e as TwinAssetError).code).toBe(code); }
  });

  it('oversized assets are rejected before parsing', () => {
    expect(() => validateGlb(new ArrayBuffer(8 * 1024 * 1024 + 1))).toThrow('assetTooLarge');
    expect(() => parseManifest({ ...manifestJson, bytes: 9 * 1024 * 1024 })).toThrow('assetTooLarge');
  });

  it('unsupported manifest schemas are rejected', () => {
    expect(() => parseManifest({ ...manifestJson, schema: 'horizon.twin-asset.v2' })).toThrow('assetSchemaUnsupported');
    expect(() => parseManifest({ ...manifestJson, provenance: 'INFERRED_PROXY' })).toThrow('assetSchemaUnsupported');
    expect(() => parseManifest(null)).toThrow('assetSchemaUnsupported');
  });

  it('a missing asset or a hash mismatch fails closed', async () => {
    const missing = (async () => new Response('nope', { status: 404 })) as unknown as typeof fetch;
    await expect(fetchTwinAsset('/', missing)).rejects.toMatchObject({ code: 'assetMissing' });
    const tampered = (async (url: string) => (url.endsWith('.json')
      ? new Response(JSON.stringify(manifestJson))
      : new Response(glb({ asset: { version: '2.0' } })))) as unknown as typeof fetch;
    await expect(fetchTwinAsset('/', tampered)).rejects.toMatchObject({ code: 'assetHashMismatch' });
  });

  it('maps STL millimetres to scene metres with the manifest transform', () => {
    const m = parseManifest(manifestJson);
    const [x, y, z] = toScene(m, m.geometry.transform.centreMm as [number, number, number]);
    expect([x, y, z].map((v) => Math.abs(v))).toEqual([0, 0, 0]);
  });
});
