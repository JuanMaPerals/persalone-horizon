import { type ChangeEvent, type ReactElement, useMemo, useState } from 'react';

import {
  COMMUNITY_SCENARIO_SCHEMA,
  communityScenarios,
  parseCommunityContribution,
  serializeCommunityContribution,
  type CommunityInteraction,
  type CommunityScenario,
  type HudColor,
} from '../community/scenarios';
import { useTraceSnapshot, useTraceStore } from '../store/TraceStoreContext';
import type { HaloTraceEvent } from '../types/trace';

const hudColors: Record<HudColor, string> = {
  cyan: '#7dd3fc',
  green: '#86efac',
  amber: '#fcd34d',
  white: '#f8fafc',
};

function simulatedEvent(
  sessionId: string,
  sequence: number,
  domain: HaloTraceEvent['domain'],
  kind: HaloTraceEvent['kind'],
  title: string,
  summary: string,
  attributes: HaloTraceEvent['attributes'] = {},
  offsetMs = 0,
): HaloTraceEvent {
  const now = Date.now() + offsetMs;
  const traceId = `community-${sessionId}`;
  return {
    id: `community-${now}-${sequence}-${kind.replaceAll('.', '-')}`,
    sessionId,
    sequence,
    occurredAt: new Date(now).toISOString(),
    domain,
    kind,
    severity: 'info',
    evidence: 'SIMULATED',
    title,
    summary,
    relation: {
      traceId,
      spanId: `community-span-${sequence}`,
    },
    tags: ['community-lab', 'simulated'],
    attributes,
    redacted: true,
  };
}

function downloadJson(filename: string, payload: string): void {
  const blob = new Blob([payload], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}

export function CommunityLab(): ReactElement {
  const store = useTraceStore();
  const snapshot = useTraceSnapshot();
  const [scenario, setScenario] = useState<CommunityScenario>(communityScenarios[0]);
  const [pageIndex, setPageIndex] = useState(0);
  const [brightness, setBrightness] = useState(scenario.brightness);
  const [fontSize, setFontSize] = useState(scenario.fontSize);
  const [textColor, setTextColor] = useState<HudColor>(scenario.textColor);
  const [status, setStatus] = useState('Ready · local simulation only');
  const [importError, setImportError] = useState<string | null>(null);

  const page = scenario.pages[pageIndex] ?? scenario.pages[0] ?? '';
  const sessionId = snapshot.activeSessionId ?? 'community-lab-session';
  const sequenceBase = snapshot.events.length + 100;

  const effectiveScenario = useMemo<CommunityScenario>(() => ({
    ...scenario,
    brightness,
    fontSize,
    textColor,
  }), [brightness, fontSize, scenario, textColor]);

  const selectScenario = (next: CommunityScenario): void => {
    setScenario(next);
    setPageIndex(0);
    setBrightness(next.brightness);
    setFontSize(next.fontSize);
    setTextColor(next.textColor);
    setImportError(null);
    setStatus('Ready · local simulation only');
  };

  const runScenario = (): void => {
    const events: HaloTraceEvent[] = [
      simulatedEvent(
        sessionId,
        sequenceBase,
        'session',
        'session.started',
        'Community scenario started',
        `${scenario.title} started in the browser-only simulation boundary.`,
        { scenario_id: scenario.id, schema: COMMUNITY_SCENARIO_SCHEMA },
      ),
      simulatedEvent(
        sessionId,
        sequenceBase + 1,
        scenario.id === 'vision-phone-bridge' ? 'vision' : 'agent',
        scenario.id === 'vision-phone-bridge' ? 'vision.frame.captured' : 'agent.response',
        scenario.id === 'vision-phone-bridge' ? 'Simulated frame captured' : 'Scenario response prepared',
        'No physical sensor, model call, transcript or personal payload is persisted.',
        { capability_count: scenario.capabilities.length, physical_claim: false },
        20,
      ),
      simulatedEvent(
        sessionId,
        sequenceBase + 2,
        'display',
        'display.page.changed',
        'HUD page rendered',
        `Rendered page 1 of ${scenario.pages.length} in the circular simulator.`,
        { page: 1, total_pages: scenario.pages.length, brightness, font_size: fontSize, color: textColor },
        40,
      ),
    ];
    store.append(events);
    setPageIndex(0);
    setStatus(`Running · ${scenario.title} · SIMULATED`);
  };

  const applyInteraction = (interaction: CommunityInteraction): void => {
    let nextPage = pageIndex;
    if (interaction === 'tap') nextPage = (pageIndex + 1) % scenario.pages.length;
    if (interaction === 'doubleTap') nextPage = 0;
    if (interaction === 'longPress') setStatus('Stopped · local simulation only');

    setPageIndex(nextPage);
    store.append([
      simulatedEvent(
        sessionId,
        sequenceBase + 3,
        'input',
        'input.gesture',
        `Gesture: ${interaction}`,
        'Community Lab injected a local gesture event.',
        { gesture: interaction },
      ),
      simulatedEvent(
        sessionId,
        sequenceBase + 4,
        'display',
        'display.page.changed',
        'HUD page changed',
        `Page ${nextPage + 1} of ${scenario.pages.length} is now visible.`,
        { page: nextPage + 1, total_pages: scenario.pages.length },
        1,
      ),
    ]);
  };

  const importContribution = async (event: ChangeEvent<HTMLInputElement>): Promise<void> => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    try {
      const imported = parseCommunityContribution(await file.text());
      selectScenario(imported);
      setStatus('Imported · SIMULATED contribution');
    } catch (error) {
      setImportError(error instanceof Error ? error.message : 'Contribution import failed.');
    }
  };

  const exportContribution = (): void => {
    const payload = serializeCommunityContribution(effectiveScenario);
    downloadJson(`${effectiveScenario.id}.halo-community.json`, payload);
    setStatus('Exported · contribution manifest');
  };

  return (
    <section className="community-lab">
      <header className="community-lab-header">
        <div>
          <span className="eyebrow">COMMUNITY / DIGITAL TWIN</span>
          <h2>HALO Community Lab</h2>
          <p>Test interaction ideas against a truthful 256×256 simulator, then export a versioned contribution that can be reviewed and integrated.</p>
        </div>
        <span className="evidence evidence-simulated">SIMULATED</span>
      </header>

      <div className="community-lab-grid">
        <aside className="scenario-column">
          <h3>Scenarios</h3>
          <div className="scenario-list">
            {communityScenarios.map((item) => (
              <button
                key={item.id}
                type="button"
                className={item.id === scenario.id ? 'scenario-card is-active' : 'scenario-card'}
                onClick={() => selectScenario(item)}
              >
                <strong>{item.title}</strong>
                <span>{item.purpose}</span>
              </button>
            ))}
          </div>
          <label className="import-control">
            Import community JSON
            <input type="file" accept="application/json,.json" onChange={(event) => void importContribution(event)} />
          </label>
          {importError && <p className="community-error">{importError}</p>}
        </aside>

        <div className="simulator-column">
          <div className="simulator-toolbar">
            <button type="button" onClick={runScenario}>Run scenario</button>
            {scenario.interactions.map((interaction) => (
              <button key={interaction} type="button" onClick={() => applyInteraction(interaction)}>
                {interaction}
              </button>
            ))}
          </div>

          <div className="halo-preview-shell" aria-label="Simulated Halo 256 by 256 display">
            <div
              className="halo-preview"
              style={{
                opacity: Math.max(brightness / 100, 0.2),
                color: hudColors[textColor],
                fontSize: `${fontSize}px`,
              }}
            >
              <span className="hud-truth">SIM</span>
              <div className="hud-copy">{page}</div>
              <small>{pageIndex + 1}/{scenario.pages.length}</small>
            </div>
          </div>

          <div className="simulator-controls">
            <label>Brightness <input type="range" min="5" max="100" value={brightness} onChange={(event) => setBrightness(Number(event.target.value))} /></label>
            <label>Font <input type="range" min="12" max="30" value={fontSize} onChange={(event) => setFontSize(Number(event.target.value))} /></label>
            <label>Color
              <select value={textColor} onChange={(event) => setTextColor(event.target.value as HudColor)}>
                <option value="cyan">Cyan</option>
                <option value="green">Green</option>
                <option value="amber">Amber</option>
                <option value="white">White</option>
              </select>
            </label>
          </div>
        </div>

        <aside className="contribution-column">
          <h3>Contribution contract</h3>
          <dl className="community-contract">
            <div><dt>Schema</dt><dd>{COMMUNITY_SCENARIO_SCHEMA}</dd></div>
            <div><dt>Evidence</dt><dd>SIMULATED only</dd></div>
            <div><dt>Pages</dt><dd>{scenario.pages.length}</dd></div>
            <div><dt>Capabilities</dt><dd>{scenario.capabilities.join(', ')}</dd></div>
          </dl>
          <button type="button" className="export-button" onClick={exportContribution}>Export contribution JSON</button>
          <p className="community-status">{status}</p>
          <p className="community-note">Imports are local-only, bounded to 64 KB and cannot promote themselves to MEASURED or physical-device evidence.</p>
        </aside>
      </div>
    </section>
  );
}