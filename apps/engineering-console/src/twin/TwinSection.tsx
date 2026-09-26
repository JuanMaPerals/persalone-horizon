/// <reference types="vite/client" />
import { type KeyboardEvent, type ReactElement, Suspense, lazy, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { Object3D } from 'three';
import { type Locale, translate } from '../i18n/i18n';
import type { MessageKey } from '../i18n/messages';
import { RuntimeStreamClient, type LiveSnapshot } from '../runtime/liveStream';
import type { CompanionClient, Gesture, RunView } from '../studio/companionClient';
import { TwinAssetError, fetchTwinAsset, type TwinAssetManifest } from './assetLoader';
import { TWIN_COMPONENTS, findComponent, type ComponentId } from './components';
import type { PerfResult, TwinMode } from './HaloTwinScene';
import { SEGMENTS, mapTwinState, type SegmentId } from './twinStateMapper';

const HaloTwinScene = lazy(() => import('./HaloTwinScene'));
const MODES: readonly TwinMode[] = ['ASSEMBLED', 'EXPLODED', 'X_RAY', 'SIGNAL_FLOW', 'LIVE_FRAMEBUFFER', 'COMPONENT_STATE'];
const gestures: readonly Gesture[] = ['single', 'double', 'long'];
const segmentNodes: Record<SegmentId, readonly [string, string]> = {
  MIC_STT: ['MIC', 'STT'], STT_TRANSLATION: ['STT', 'TRANSLATION'], TRANSLATION_CAPTION: ['TRANSLATION', 'CAPTION'],
  CAPTION_DISPLAY: ['CAPTION', 'DISPLAY'], TRANSLATION_TTS: ['TRANSLATION', 'TTS'], TTS_SPEAKER: ['TTS', 'SPEAKER'],
};

type AssetState =
  | { readonly status: 'loading' }
  | { readonly status: 'ready'; readonly manifest: TwinAssetManifest; readonly shell: Object3D; readonly loadMs: number }
  | { readonly status: 'error'; readonly code: string }
  | { readonly status: 'noWebgl' };

export function webglAvailable(): boolean {
  try {
    const canvas = document.createElement('canvas');
    return Boolean(canvas.getContext('webgl2') ?? canvas.getContext('webgl'));
  } catch {
    return false;
  }
}

function useReducedMotion(): boolean {
  const query = typeof window !== 'undefined' && window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  const [reduced, setReduced] = useState(query?.matches ?? false);
  useEffect(() => {
    if (!query) return;
    const on = () => setReduced(query.matches);
    query.addEventListener('change', on);
    return () => query.removeEventListener('change', on);
  }, [query]);
  return reduced;
}

export interface TwinSectionProps {
  readonly locale: Locale;
  readonly client: CompanionClient | null;
  /** Canonical runtime event stream announced by the Companion. */
  readonly eventsUrl: string | null;
  readonly run: RunView | null;
  readonly busy: boolean;
  readonly onPress: (gesture: Gesture) => void;
}

/** Studio V2: the Halo digital twin, driven by the canonical runtime stream. */
export function TwinSection({ locale, client, eventsUrl, run, busy, onPress }: TwinSectionProps): ReactElement {
  const t = useCallback((key: MessageKey, p?: Readonly<Record<string, string | number>>) => translate(locale, key, p), [locale]);
  const reducedMotion = useReducedMotion();
  const [snapshot, setSnapshot] = useState<LiveSnapshot | null>(null);
  const [mode, setMode] = useState<TwinMode>('ASSEMBLED');
  const [selected, setSelected] = useState<ComponentId | null>(null);
  const [unknownRequested, setUnknownRequested] = useState<string | null>(null);
  const [asset, setAsset] = useState<AssetState>({ status: 'loading' });
  const [frame, setFrame] = useState<{ url: string; seq: number } | null>(null);
  const [perfRequest, setPerfRequest] = useState(0);
  const [perf, setPerf] = useState<PerfResult | null>(null);
  const urls = useRef<string[]>([]);

  // Deep link: #twin=<componentId>. Unknown ids are reported, never guessed.
  useEffect(() => {
    const match = /(?:^|[#&])twin=([\w-]+)/.exec(window.location.hash);
    if (!match) return;
    if (findComponent(match[1])) setSelected(match[1] as ComponentId);
    else setUnknownRequested(match[1]);
  }, []);

  // Canonical stream through the existing fail-closed client.
  useEffect(() => {
    if (!eventsUrl) return;
    const stream = new RuntimeStreamClient({ url: eventsUrl, onChange: setSnapshot });
    stream.start();
    return () => stream.stop();
  }, [eventsUrl]);

  // Validated model load (skipped entirely without WebGL).
  useEffect(() => {
    if (!webglAvailable()) {
      setAsset({ status: 'noWebgl' });
      return;
    }
    let cancelled = false;
    const started = performance.now();
    (async () => {
      try {
        const fetched = await fetchTwinAsset(import.meta.env.BASE_URL);
        const { parseShell } = await import('./glbParse');
        const shell = await parseShell(fetched.buffer);
        if (!cancelled) setAsset({ status: 'ready', manifest: fetched.manifest, shell, loadMs: performance.now() - started });
      } catch (error) {
        if (!cancelled) setAsset({ status: 'error', code: error instanceof TwinAssetError ? error.code : 'assetMalformed' });
      }
    })();
    return () => { cancelled = true; };
  }, []);

  useEffect(() => () => urls.current.forEach((u) => URL.revokeObjectURL(u)), []);

  const twin = useMemo(() => mapTwinState(snapshot?.connection ?? 'IDLE', snapshot?.events ?? []), [snapshot]);

  // The twin display shows the real framebuffer only for the live session
  // it belongs to, refreshed on each caption event; otherwise UNKNOWN.
  const running = run?.state === 'running';
  const current = twin.live && running && twin.sessionId === run?.runId && twin.captionSeq !== null;
  useEffect(() => {
    if (!current || !client || !run) {
      setFrame(null);
      return;
    }
    let cancelled = false;
    client.framebuffer(run.runId).then((f) => {
      if (cancelled) return;
      const url = URL.createObjectURL(f.png);
      urls.current.push(url);
      setFrame({ url, seq: twin.captionSeq! });
    }).catch(() => { if (!cancelled) setFrame(null); });
    return () => { cancelled = true; };
  }, [current, client, run, twin.captionSeq]);

  const liveFrame = current && frame !== null && frame.seq === twin.captionSeq ? frame.url : null;
  const selectedComponent = selected ? findComponent(selected) : undefined;
  const state = selected ? twin.components[selected] : undefined;
  const labels = useMemo(() => Object.fromEntries([
    ...TWIN_COMPONENTS.map((c) => [`c.${c.id}`, t(`twin.c.${c.id}` as MessageKey)]),
    ...['MIC', 'STT', 'TRANSLATION', 'CAPTION', 'DISPLAY', 'TTS', 'SPEAKER'].map((n) => [`flow.${n}`, t(`twin.flow.${n}` as MessageKey)]),
  ]), [t]);

  const onTreeKey = (e: KeyboardEvent<HTMLUListElement>) => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    e.preventDefault();
    const ids = TWIN_COMPONENTS.map((c) => c.id);
    // Move from the focused item (keyboard users), else from the selection.
    const focused = (document.activeElement as HTMLElement | null)?.dataset.component as ComponentId | undefined;
    const from = focused && ids.includes(focused) ? focused : selected;
    const index = from ? ids.indexOf(from) : -1;
    const next = ids[(index + (e.key === 'ArrowDown' ? 1 : ids.length - 1)) % ids.length];
    setSelected(next);
    (e.currentTarget.querySelector(`[data-component="${next}"]`) as HTMLElement | null)?.focus();
  };

  const activityText = (id: ComponentId) => {
    const s = twin.components[id];
    return s.activity === 'lastGesture' ? t('twin.act.lastGesture', { gesture: s.detail ?? '?' }) : t(`twin.act.${s.activity}` as MessageKey);
  };

  return <section className="studio-step twin" aria-labelledby="twin-heading"
    data-twin-mode={mode} data-live={twin.live ? 'true' : 'false'} data-display={liveFrame ? 'live' : 'unknown'} data-motion={reducedMotion ? 'reduced' : 'full'}>
    <h3 id="twin-heading">{t('twin.heading')}</h3>
    <p role="status" data-connection={twin.connection}>{t('twin.stream')}: <strong>{t(`twin.conn.${twin.connection}` as MessageKey)}</strong>{twin.live ? '' : ` · ${t('twin.notLive')}`}</p>
    {unknownRequested ? <p className="studio-warning" role="alert">{t('twin.unknownComponent', { id: unknownRequested })}</p> : null}

    <div className="twin-modes" role="radiogroup" aria-label={t('twin.modes')}>
      {MODES.map((m) => <button key={m} type="button" role="radio" aria-checked={mode === m} data-mode={m} onClick={() => setMode(m)}>{t(`twin.mode.${m}` as MessageKey)}</button>)}
    </div>

    <div className="twin-layout">
      <div className="twin-viewport" role="img" aria-label={`${t('twin.heading')} · ${t(`twin.mode.${mode}` as MessageKey)} · ${liveFrame && run ? t('twin.frame.live', { page: run.page, count: run.pageCount }) : t('twin.frame.unknown')}`}>
        {asset.status === 'noWebgl' ? <p className="studio-note" role="note">{t('twin.webglUnavailable')}</p> : null}
        {asset.status === 'error' ? <p className="studio-warning" role="alert" data-asset-error={asset.code}>{t('twin.assetError', { code: asset.code })}</p> : null}
        {asset.status === 'loading' ? <p className="studio-muted">{t('twin.loading')}</p> : null}
        {asset.status === 'ready' ? <Suspense fallback={<p className="studio-muted">{t('twin.loading')}</p>}>
          <HaloTwinScene manifest={asset.manifest} shell={asset.shell} twin={twin} mode={mode} selected={selected} onSelect={setSelected}
            frameUrl={liveFrame} reducedMotion={reducedMotion} perfRequest={perfRequest} onPerf={setPerf} labels={labels} />
        </Suspense> : null}
      </div>

      <div className="twin-side">
        <h4 id="twin-tree">{t('twin.components')}</h4>
        <small>{t('twin.selectHint')}</small>
        <ul className="twin-tree" aria-labelledby="twin-tree" onKeyDown={onTreeKey}>
          {TWIN_COMPONENTS.map((c) => {
            const s = twin.components[c.id];
            return <li key={c.id}>
              <button type="button" data-component={c.id} aria-pressed={selected === c.id} data-environment={s.environment} data-evidence={s.evidence} data-activity={s.activity}
                onClick={() => setSelected(c.id)}>
                <span>{t(`twin.c.${c.id}` as MessageKey)}</span>
                <small>{t(`twin.env.${s.environment}` as MessageKey)} · {t(`twin.ev.${s.evidence}` as MessageKey)}</small>
              </button>
            </li>;
          })}
        </ul>
      </div>
    </div>

    <div className="twin-detail" aria-live="polite">
      {selectedComponent && state ? <dl className="studio-facts" data-selected={selectedComponent.id}>
        <div><dt>{t('twin.c.' + selectedComponent.id as MessageKey)}</dt><dd>{t(`twin.cap.${selectedComponent.capability}` as MessageKey)}</dd></div>
        <div><dt>{t('twin.field.provenance')}</dt><dd data-provenance={selectedComponent.provenance}>{t(`twin.prov.${selectedComponent.provenance}` as MessageKey)}</dd></div>
        <div><dt>{t('twin.field.environment')}</dt><dd data-environment={state.environment}>{t(`twin.env.${state.environment}` as MessageKey)}</dd></div>
        <div><dt>{t('twin.field.evidence')}</dt><dd data-evidence={state.evidence}>{t(`twin.ev.${state.evidence}` as MessageKey)}</dd></div>
        <div><dt>{t('twin.field.activity')}</dt><dd data-activity={state.activity}>{activityText(selectedComponent.id)}</dd></div>
        <div><dt>{t('twin.field.source')}</dt><dd><code>{selectedComponent.source}</code></dd></div>
        <div><dt>{t('twin.field.note')}</dt><dd lang="en">{selectedComponent.note}</dd></div>
      </dl> : <p className="studio-muted">{t('twin.noSelection')}</p>}
      {selected === 'button' ? <div className="studio-row">
        {gestures.map((g) => <button key={g} type="button" data-twin-press={g} disabled={busy || !running} onClick={() => onPress(g)}>
          {t('twin.press', { gesture: t(`editor.gesture.${g}` as MessageKey) })}</button>)}
        {!running ? <small>{t('twin.pressNeedsRun')}</small> : null}
      </div> : null}
    </div>

    <p className={liveFrame ? 'studio-ok' : 'studio-muted'} data-frame={liveFrame ? 'live' : 'unknown'}>
      {liveFrame && run ? t('twin.frame.live', { page: run.page, count: run.pageCount }) : t('twin.frame.unknown')}
    </p>

    <h4>{t('twin.flow.heading')}</h4>
    <ol className="twin-flow">
      {SEGMENTS.map((s) => {
        const seg = twin.segments[s];
        const [a, b] = segmentNodes[s];
        return <li key={s} data-segment={s} data-active={seg.active ? 'true' : 'false'}>
          {t(`twin.flow.${a}` as MessageKey)} → {t(`twin.flow.${b}` as MessageKey)}: <strong>{seg.active ? t('twin.flow.active', { proof: seg.proof ?? '' }) : t('twin.flow.inactive')}</strong>
        </li>;
      })}
    </ol>

    {asset.status === 'ready' ? <>
      <p className="studio-muted" data-model-sha={asset.manifest.sha256}>{t('twin.modelSource', { triangles: asset.manifest.geometry.triangles, bytes: asset.manifest.bytes, sha: `${asset.manifest.sha256.slice(0, 12)}…` })}</p>
      <h4>{t('twin.perf.heading')}</h4>
      <button type="button" data-perf-measure onClick={() => setPerfRequest((n) => n + 1)} disabled={perfRequest > 0 && perf === null}>
        {perfRequest > 0 && perf === null ? t('twin.perf.measuring') : t('twin.perf.measure')}</button>
      <table className="latency-table" data-perf={perf ? 'measured' : 'none'}>
        <tbody>
          <tr><th scope="row">{t('twin.perf.load')}</th><td data-load-ms={asset.loadMs.toFixed(1)}>{asset.loadMs.toFixed(1)} ms</td></tr>
          <tr><th scope="row">{t('twin.perf.bytes')}</th><td>{asset.manifest.bytes}</td></tr>
          {perf ? <>
            <tr><th scope="row">{t('twin.perf.triangles')}</th><td data-triangles={perf.triangles}>{perf.triangles}</td></tr>
            <tr><th scope="row">{t('twin.perf.drawCalls')}</th><td data-draw-calls={perf.drawCalls}>{perf.drawCalls}</td></tr>
            <tr><th scope="row">{t('twin.perf.frameTime')}</th><td data-frame-p50={perf.frameMsP50.toFixed(2)} data-frame-p95={perf.frameMsP95.toFixed(2)}>{perf.frameMsP50.toFixed(2)} / {perf.frameMsP95.toFixed(2)} ms</td></tr>
            <tr><th scope="row">{t('twin.perf.fps')}</th><td data-fps-p50={perf.fpsP50.toFixed(1)} data-fps-p95={perf.fpsP95.toFixed(1)}>{perf.fpsP50.toFixed(1)} / {perf.fpsP95.toFixed(1)}</td></tr>
            <tr><th scope="row">{t('twin.perf.frames')}</th><td>{perf.frames}</td></tr>
            <tr><th scope="row">{t('twin.perf.renderer')}</th><td data-renderer={perf.renderer}>{perf.renderer}</td></tr>
          </> : <tr><td colSpan={2}>{t('twin.perf.none')}</td></tr>}
        </tbody>
      </table>
    </> : null}
  </section>;
}
