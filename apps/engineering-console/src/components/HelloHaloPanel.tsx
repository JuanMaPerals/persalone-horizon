import { type ReactElement, type ReactNode, useEffect, useMemo, useRef, useState } from 'react';
import { LOCALES, type Locale, catalogStatus, errorMessage, localeNames, plural, translate, useLocale } from '../i18n/i18n';
import type { MessageKey } from '../i18n/messages';
import {
  CompanionClient,
  CompanionError,
  type ButtonOutcome,
  type ExportedPackage,
  type Gesture,
  type Health,
  type Metric,
  type ProjectView,
  type RunView,
  type TestResult,
} from '../studio/companionClient';

const gestures: readonly Gesture[] = ['single', 'double', 'long'];
const defaultUrl = 'http://127.0.0.1:47810';

type Busy = null | 'connect' | 'create' | 'save' | 'run' | 'button' | 'frame' | 'stop' | 'panic' | 'test' | 'export';

interface Problem {
  readonly code: string;
  readonly params: Readonly<Record<string, string | number>>;
}

/** Studio V1 "Hello Halo" journey: create → edit → run on the official emulator → framebuffer → button → test → export. */
export function HelloHaloPanel({ fetchImpl, preferredLocale }: { readonly fetchImpl?: typeof fetch; readonly preferredLocale?: Locale } = {}): ReactElement {
  const { locale, setLocale } = useLocale(preferredLocale);
  const t = (key: MessageKey, params?: Readonly<Record<string, string | number>>) => translate(locale, key, params);

  const [url, setUrl] = useState(defaultUrl);
  const [token, setToken] = useState('');
  const [client, setClient] = useState<CompanionClient | null>(null);
  const [health, setHealth] = useState<Health | null>(null);
  const [unreachable, setUnreachable] = useState(false);
  const [name, setName] = useState('Hello Halo');
  const [project, setProject] = useState<ProjectView | null>(null);
  const [caption, setCaption] = useState('');
  const [advanceOn, setAdvanceOn] = useState<Gesture>('single');
  const [saved, setSaved] = useState(false);
  const [run, setRun] = useState<RunView | null>(null);
  const [frame, setFrame] = useState<{ url: string; sha256: string } | null>(null);
  const [lastPress, setLastPress] = useState<ButtonOutcome | null>(null);
  const [result, setResult] = useState<TestResult | null>(null);
  const [pkg, setPkg] = useState<(ExportedPackage & { url: string }) | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const [problem, setProblem] = useState<Problem | null>(null);
  const objectUrls = useRef<string[]>([]);

  useEffect(() => () => objectUrls.current.forEach((u) => URL.revokeObjectURL(u)), []);

  const track = (blob: Blob): string => {
    const objectUrl = URL.createObjectURL(blob);
    objectUrls.current.push(objectUrl);
    return objectUrl;
  };

  const act = async (kind: Exclude<Busy, null>, work: () => Promise<void>) => {
    setBusy(kind);
    setProblem(null);
    try {
      await work();
    } catch (error) {
      if (error instanceof CompanionError) {
        setProblem({ code: error.code, params: error.params });
        if (error.code === 'companionUnreachable') setUnreachable(true);
        if (error.code === 'runNotActive' && run) setRun({ ...run, state: 'stopped' });
      } else {
        setProblem({ code: 'generic', params: {} });
      }
    } finally {
      setBusy(null);
    }
  };

  const connect = () => act('connect', async () => {
    const next = new CompanionClient(url, token.trim(), fetchImpl);
    setUnreachable(false);
    setHealth(await next.health());
    setClient(next);
  });

  const create = () => act('create', async () => {
    const view = await client!.createProject(name.trim());
    setProject(view);
    setCaption(view.manifest.content.caption);
    setAdvanceOn(view.manifest.content.advanceOn);
    setSaved(true);
    setRun(null);
    setResult(null);
    setPkg(null);
  });

  const save = () => act('save', async () => {
    const view = await client!.updateContent(project!.projectId, { caption, advanceOn });
    setProject(view);
    setSaved(true);
  });

  const refreshFrame = async (runId: string) => {
    const f = await client!.framebuffer(runId);
    setFrame({ url: track(f.png), sha256: f.sha256 });
  };

  const start = () => act('run', async () => {
    const started = await client!.startRun(project!.projectId);
    setRun(started);
    setLastPress(null);
    await refreshFrame(started.runId);
  });

  const press = (gesture: Gesture) => act('button', async () => {
    const outcome = await client!.press(run!.runId, gesture);
    setLastPress(outcome);
    setRun(await client!.getRun(run!.runId));
    await refreshFrame(run!.runId);
  });

  const stop = () => act('stop', async () => {
    setRun(await client!.stop(run!.runId));
    setFrame(null);
  });

  const panic = () => act('panic', async () => {
    await client!.panic();
    if (run) setRun({ ...run, state: 'stopped', stopReason: 'panic' });
    setFrame(null);
  });

  const test = () => act('test', async () => {
    setResult(await client!.runTests(project!.projectId));
  });

  const exportIt = () => act('export', async () => {
    const exported = await client!.exportPackage(project!.projectId);
    setPkg({ ...exported, url: track(exported.bytes) });
  });

  const connectionState = unreachable ? 'UNREACHABLE' : health ? health.status : 'NOT_CONNECTED';
  const running = run?.state === 'running';
  const dirty = project !== null && (caption !== project.manifest.content.caption || advanceOn !== project.manifest.content.advanceOn);
  const preview = project?.preview;
  const emulator = health?.components.emulator;
  const emulatorBlocked = emulator?.state === 'BLOCKED';

  const labels = useMemo(() => ({ providers: run?.providers ?? result?.providers }), [run, result]);

  return <section className="studio-panel" lang={locale} aria-labelledby="studio-title">
    <header className="studio-head">
      <div>
        <h2 id="studio-title">{t('studio.title')}</h2>
        <p>{t('studio.subtitle')}</p>
      </div>
      <label className="studio-language">
        <span>{t('studio.language')}</span>
        <select value={locale} onChange={(e) => setLocale(e.target.value as Locale)}>
          {LOCALES.map((l) => <option key={l} value={l}>{localeNames[l]}{catalogStatus[l] === 'complete' ? '' : ' (draft)'}</option>)}
        </select>
      </label>
    </header>
    {catalogStatus[locale] !== 'complete' ? <p className="studio-note" role="note">{t('studio.catalogDraft')}</p> : null}
    {problem ? <p className="studio-error" role="alert">{errorMessage(locale, problem.code, problem.params)}</p> : null}

    <Step title={t('companion.heading')}>
      <div className="studio-row">
        <label><span>{t('companion.url')}</span><input value={url} onChange={(e) => setUrl(e.target.value)} spellCheck={false} /></label>
        <label><span>{t('companion.token')}</span><input value={token} onChange={(e) => setToken(e.target.value)} type="password" autoComplete="off" aria-describedby="token-hint" /></label>
        <button type="button" onClick={() => void connect()} disabled={busy !== null || token.trim() === ''}>{busy === 'connect' ? t('companion.connecting') : t('companion.connect')}</button>
      </div>
      <small id="token-hint">{t('companion.tokenHint')}</small>
      <dl className="studio-facts" aria-live="polite">
        <div><dt>{t('companion.heading')}</dt><dd data-state={connectionState}>{t(`companion.state.${connectionState}` as MessageKey)}</dd></div>
        {health ? Object.entries(health.components).filter(([k]) => k !== 'api').map(([key, c]) => <div key={key}>
          <dt>{key === 'emulator' ? t('companion.component.emulator') : key === 'halo' ? t('companion.component.halo') : key}</dt>
          <dd data-state={c.state}>{t(`companion.state.${c.state === 'READY' ? 'READY' : c.state === 'BLOCKED' ? 'BLOCKED' : 'DEGRADED'}` as MessageKey)}{c.reason ? ` · ${c.reason}` : ''}</dd>
        </div>) : null}
      </dl>
    </Step>

    <Step title={t('project.heading')}>
      <div className="studio-row">
        <label><span>{t('project.name')}</span><input value={name} onChange={(e) => setName(e.target.value)} maxLength={60} /></label>
        <button type="button" onClick={() => void create()} disabled={!client || busy !== null || name.trim() === ''}>{busy === 'create' ? t('project.creating') : t('project.create')}</button>
      </div>
      {project ? <dl className="studio-facts">
        <div><dt>{t('project.appId')}</dt><dd><code>{project.manifest.appId}</code></dd></div>
        <div><dt>{t('project.digest')}</dt><dd><code title={project.appDigest}>{project.appDigest.slice(0, 16)}…</code></dd></div>
      </dl> : <p className="studio-muted">{t('project.none')}</p>}
    </Step>

    {project && preview ? <Step title={t('editor.heading')}>
      <label className="studio-block"><span>{t('editor.caption')}</span>
        <textarea value={caption} onChange={(e) => { setCaption(e.target.value); setSaved(false); }} rows={3} maxLength={preview.maxInputChars} aria-describedby="caption-count" />
      </label>
      <small id="caption-count">{t('editor.chars', { count: caption.length, max: preview.maxInputChars })}</small>
      <div className="studio-row">
        <label><span>{t('editor.advanceOn')}</span>
          <select value={advanceOn} onChange={(e) => { setAdvanceOn(e.target.value as Gesture); setSaved(false); }}>
            {gestures.map((g) => <option key={g} value={g}>{t(`editor.gesture.${g}` as MessageKey)}</option>)}
          </select>
        </label>
        <button type="button" onClick={() => void save()} disabled={busy !== null || !dirty}>{busy === 'save' ? t('editor.saving') : t('editor.save')}</button>
        {saved && !dirty ? <span className="studio-ok" role="status">{t('editor.saved')}</span> : null}
      </div>
      <p>{plural(locale, 'editor.pages', preview.pageCount)}</p>
      {preview.replacedGlyphs > 0 ? <p className="studio-warning" role="note">{plural(locale, 'editor.glyphsReplaced', preview.replacedGlyphs)}</p> : null}
      {preview.foldedGlyphs > 0 ? <p className="studio-note" role="note">{plural(locale, 'editor.glyphsFolded', preview.foldedGlyphs)}</p> : null}
      <ol className="studio-pages">
        {preview.pages.map((lines, i) => <li key={i} aria-label={t('editor.pagePreview', { page: i + 1 })}>{lines.map((l, j) => <code key={j}>{l}</code>)}</li>)}
      </ol>
    </Step> : null}

    {project ? <Step title={t('run.heading')}>
      <div className="studio-row">
        <button type="button" onClick={() => void start()} disabled={busy !== null || dirty || emulatorBlocked} title={emulatorBlocked ? errorMessage(locale, 'emulatorBlocked', { reason: emulator?.reason ?? 'UNKNOWN' }) : undefined}>{busy === 'run' ? t('run.starting') : t('run.start')}</button>
        <button type="button" onClick={() => void stop()} disabled={busy !== null || !running}>{t('run.stop')}</button>
        <button type="button" className="studio-panic" onClick={() => void panic()} disabled={!client || busy === 'panic'} title={t('run.panicHint')} aria-describedby="panic-hint">{t('run.panic')}</button>
        <small id="panic-hint">{t('run.panicHint')}</small>
      </div>
      {run ? <>
        <p role="status">{t(`run.state.${run.state}` as MessageKey)} · {t('run.page', { page: run.page, count: run.pageCount })}</p>
        <TruthLabels locale={locale} target={run.target} data={run.data} providers={labels.providers} />
        <div className="studio-emulator">
          <div className="studio-display">{frame ? <img src={frame.url} width={256} height={256} alt={t('run.framebufferAlt', { page: run.page, count: run.pageCount })} /> : <span>{t('run.noRun')}</span>}</div>
          <div className="studio-controls">
            {gestures.map((g) => <button key={g} type="button" onClick={() => void press(g)} disabled={busy !== null || !running}>{t('run.press', { gesture: t(`editor.gesture.${g}` as MessageKey) })}</button>)}
            <button type="button" onClick={() => void act('frame', () => refreshFrame(run.runId))} disabled={busy !== null || !running}>{t('run.refreshFrame')}</button>
            {lastPress ? <p role="status">{lastPress.deviceReports.length ? t('run.deviceReported', { reports: lastPress.deviceReports.join(', ') }) : t('run.deviceReportedNothing')} {lastPress.advanced ? t('run.advanced') : t('run.notAdvanced')}</p> : null}
            {frame ? <p className="studio-muted">{t('run.framebufferHash')}: <code>{frame.sha256.slice(0, 16)}…</code></p> : null}
          </div>
        </div>
        <MetricsTable locale={locale} metrics={run.metrics} />
      </> : <p className="studio-muted">{t('run.noRun')}</p>}
    </Step> : null}

    {project ? <Step title={t('test.heading')}>
      <button type="button" onClick={() => void test()} disabled={busy !== null || dirty}>{busy === 'test' ? t('test.running') : t('test.run')}</button>
      {result ? <TestReport locale={locale} result={result} /> : <p className="studio-muted">{t('test.none')}</p>}
    </Step> : null}

    {project ? <Step title={t('export.heading')}>
      <button type="button" onClick={() => void exportIt()} disabled={busy !== null || dirty}>{busy === 'export' ? t('export.running') : t('export.run')}</button>
      <p className="studio-muted">{t('export.includesTest')}</p>
      {pkg ? <dl className="studio-facts">
        <div><dt>{t('export.done')}</dt><dd><a href={pkg.url} download={pkg.fileName}>{t('export.download', { file: pkg.fileName })}</a></dd></div>
        <div><dt>{t('export.sha')}</dt><dd><code>{pkg.sha256}</code></dd></div>
      </dl> : null}
    </Step> : null}
  </section>;
}

function Step({ title, children }: { readonly title: string; readonly children: ReactNode }): ReactElement {
  return <section className="studio-step"><h3>{title}</h3>{children}</section>;
}

function TruthLabels({ locale, target, data, providers, outcome, evidence }: {
  readonly locale: Locale;
  readonly target: string;
  readonly data: string;
  readonly providers?: Readonly<Record<string, string>>;
  readonly outcome?: string;
  readonly evidence?: string;
}): ReactElement {
  const t = (key: MessageKey) => translate(locale, key);
  const value = (v: string) => (`value.${v}` in { ...valueKeys } ? t(`value.${v}` as MessageKey) : v);
  return <dl className="studio-truth">
    <div><dt>{t('labels.data')}</dt><dd>{value(data)}</dd></div>
    <div><dt>{t('labels.target')}</dt><dd>{value(target)}</dd></div>
    {providers ? <div><dt>{t('labels.providers')}</dt><dd>{Object.entries(providers).map(([k, v]) => `${t(`provider.${k}` as MessageKey)}: ${value(v)}`).join(' · ')}</dd></div> : null}
    {outcome ? <div><dt>{t('labels.result')}</dt><dd data-outcome={outcome}>{t(`test.outcome.${outcome}` as MessageKey)}</dd></div> : null}
    {evidence ? <div><dt>{t('labels.evidence')}</dt><dd>{value(evidence)}</dd></div> : null}
    <p className="studio-muted">{t('labels.scope')}</p>
  </dl>;
}

const valueKeys = {
  'value.SYNTHETIC': 1, 'value.EMULATED': 1, 'value.NOT_USED': 1, 'value.MEASURED': 1, 'value.UNKNOWN': 1, 'value.NOT_AVAILABLE': 1,
} as const;

function MetricsTable({ locale, metrics }: { readonly locale: Locale; readonly metrics: readonly Metric[] }): ReactElement {
  const t = (key: MessageKey, p?: Readonly<Record<string, string | number>>) => translate(locale, key, p);
  const ms = (v: number | null, min: number) => (v === null ? t('test.insufficient', { count: min }) : `${new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(v)} ms`);
  return <table className="latency-table">
    <caption>{t('test.metrics')}</caption>
    <thead><tr><th scope="col">{t('test.metric')}</th><th scope="col">{t('test.latest')}</th><th scope="col">p50</th><th scope="col">p95</th><th scope="col">{t('test.samples')}</th></tr></thead>
    <tbody>{metrics.map((m) => <tr key={m.name}>
      <th scope="row"><code>{m.name}</code></th>
      <td>{m.latest === null ? t('value.NOT_AVAILABLE') : ms(m.latest, 1)}</td>
      <td>{m.samples === 0 ? t('value.NOT_AVAILABLE') : ms(m.p50, 5)}</td>
      <td>{m.samples === 0 ? t('value.NOT_AVAILABLE') : ms(m.p95, 20)}</td>
      <td>{m.samples}</td>
    </tr>)}</tbody>
  </table>;
}

function TestReport({ locale, result }: { readonly locale: Locale; readonly result: TestResult }): ReactElement {
  const t = (key: MessageKey, p?: Readonly<Record<string, string | number>>) => translate(locale, key, p);
  const show = (v: unknown) => (typeof v === 'string' ? v : JSON.stringify(v));
  return <div className="studio-report" aria-live="polite">
    <TruthLabels locale={locale} target={result.target} data={result.data.provenance} providers={result.providers} outcome={result.outcome} evidence={result.evidence} />
    {result.blockedReason ? <p className="studio-warning">{t('test.blockedReason', { reason: result.blockedReason })}</p> : null}
    <p className="studio-muted">{t('test.duration', { ms: result.durationMs })} · <code>{result.runId}</code></p>
    {result.assertions.length ? <table className="latency-table">
      <thead><tr><th scope="col">{t('test.assertion')}</th><th scope="col">{t('test.expected')}</th><th scope="col">{t('test.actual')}</th><th scope="col">{t('test.status')}</th></tr></thead>
      <tbody>{result.assertions.map((a) => <tr key={a.id}>
        <th scope="row">{`assertion.${a.id}` in assertionKeys ? t(`assertion.${a.id}` as MessageKey) : a.id}</th>
        <td>{show(a.expected)}</td><td>{show(a.actual)}</td>
        <td data-outcome={a.status}>{t(`test.outcome.${a.status}` as MessageKey)}</td>
      </tr>)}</tbody>
    </table> : null}
    {result.metrics.length ? <MetricsTable locale={locale} metrics={result.metrics} /> : null}
    {result.artifacts.length ? <><h4>{t('test.artifacts')}</h4><ul>{result.artifacts.map((a) => <li key={a.name}><code>{a.name}</code> · {a.bytes} B · <code>{a.sha256.slice(0, 16)}…</code></li>)}</ul></> : null}
  </div>;
}

const assertionKeys = {
  'assertion.manifest.valid': 1, 'assertion.composition.noLoss': 1, 'assertion.display.page1Visible': 1,
  'assertion.display.insideVisibleCircle': 1, 'assertion.glyphs.reported': 1, 'assertion.button.deviceReport': 1,
  'assertion.button.advancesPage': 1, 'assertion.button.otherGestureIgnored': 1, 'assertion.stop.clearsDisplay': 1,
} as const;
