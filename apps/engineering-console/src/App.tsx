import { DockviewReact, type DockviewApi, type DockviewReadyEvent, type IDockviewPanelProps } from 'dockview-react';
import { type ReactElement, useEffect, useRef, useState } from 'react';
import { ConsolePanel, type ConsolePanelId } from './components/ConsolePanel';
import { useTraceSnapshot, useTraceStore } from './store/TraceStoreContext';

import 'dockview-react/dist/styles/dockview.css';

const layoutStorageKey = 'persalone.halo.engineering-console.v2.layout';

interface PanelDefinition {
  readonly id: ConsolePanelId;
  readonly title: string;
  readonly group: 'Observe' | 'Inspect' | 'Systems';
}

const panels: readonly PanelDefinition[] = [
  { id: 'execution-graph', title: 'Execution Graph', group: 'Observe' },
  { id: 'timeline', title: 'Timeline & Replay', group: 'Observe' },
  { id: 'logs', title: 'Trace Logs', group: 'Observe' },
  { id: 'inspector', title: 'Inspector', group: 'Inspect' },
  { id: 'translation', title: 'Translation Inspector', group: 'Inspect' },
  { id: 'memory-rag', title: 'Memory / RAG', group: 'Inspect' },
  { id: 'ble-monitor', title: 'BLE Monitor', group: 'Systems' },
  { id: 'metrics', title: 'Metrics & Latency', group: 'Systems' },
];

function DockPanel(props: IDockviewPanelProps<{ panelId: ConsolePanelId }>): ReactElement {
  return <ConsolePanel panelId={props.params.panelId} />;
}

function ConsoleHeader({ onPalette }: { readonly onPalette: () => void }): ReactElement {
  const store = useTraceStore();
  const snapshot = useTraceSnapshot();
  return <header className="console-header">
    <div className="brand-lockup"><span className="brand-mark">H</span><div><strong>HALO</strong><span>Engineering Console V2</span></div></div>
    <div className="session-picker"><label htmlFor="session-select">Session</label><select id="session-select" value={snapshot.activeSessionId ?? ''} onChange={(event) => store.selectSession(event.target.value)}>{snapshot.sessions.map((session) => <option key={session.id} value={session.id}>{session.label}</option>)}</select></div>
    <label className="global-search"><span>Search</span><input value={snapshot.filters.text} onChange={(event) => store.setSearch(event.target.value)} placeholder="Events, domains, tags…" /></label>
    <button type="button" className="command-trigger" onClick={onPalette}><kbd>⌘</kbd><kbd>K</kbd> Command palette</button>
    <div className="truth-banner"><span>TRACE SOURCE</span><strong>EMULATED</strong></div>
  </header>;
}

function CommandPalette({ api, onClose }: { readonly api: DockviewApi | null; readonly onClose: () => void }): ReactElement | null {
  const [query, setQuery] = useState('');
  if (!api) return null;
  const results = panels.filter((panel) => panel.title.toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  const activate = (id: ConsolePanelId) => {
    api.getPanel(id)?.api.setActive();
    onClose();
  };
  return <div className="command-backdrop" role="presentation" onMouseDown={onClose}><section className="command-palette" role="dialog" aria-modal="true" aria-label="Command palette" onMouseDown={(event) => event.stopPropagation()}><input autoFocus value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Type a command or panel name…" /><div className="command-results">{results.map((panel) => <button type="button" key={panel.id} onClick={() => activate(panel.id)}><span>{panel.title}</span><small>{panel.group}</small></button>)}</div><footer><span>Navigate workspace</span><kbd>Esc</kbd> to close</footer></section></div>;
}

function buildDefaultLayout(api: DockviewApi): void {
  const add = (id: ConsolePanelId, title: string, position?: Parameters<DockviewApi['addPanel']>[0]['position']) => api.addPanel({ id, component: 'panel', title, params: { panelId: id }, position });
  add('execution-graph', 'Execution Graph');
  add('inspector', 'Inspector', { referencePanel: 'execution-graph', direction: 'right' });
  add('timeline', 'Timeline & Replay', { referencePanel: 'execution-graph', direction: 'below' });
  add('logs', 'Trace Logs', { referencePanel: 'timeline', direction: 'below' });
  add('ble-monitor', 'BLE Monitor', { referencePanel: 'inspector', direction: 'below' });
  add('translation', 'Translation Inspector', { referencePanel: 'ble-monitor', direction: 'below' });
  add('memory-rag', 'Memory / RAG', { referencePanel: 'translation', direction: 'below' });
  add('metrics', 'Metrics & Latency', { referencePanel: 'logs', direction: 'right' });
}

function Workstation(): ReactElement {
  const apiRef = useRef<DockviewApi | null>(null);
  const [api, setApi] = useState<DockviewApi | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLocaleLowerCase() === 'k') {
        event.preventDefault();
        setPaletteOpen(true);
      }
      if (event.key === 'Escape') setPaletteOpen(false);
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  const onReady = (event: DockviewReadyEvent) => {
    apiRef.current = event.api;
    setApi(event.api);
    const saved = window.localStorage.getItem(layoutStorageKey);
    try {
      if (saved) event.api.fromJSON(JSON.parse(saved));
      else buildDefaultLayout(event.api);
    } catch {
      window.localStorage.removeItem(layoutStorageKey);
      buildDefaultLayout(event.api);
    }
    event.api.onDidLayoutChange(() => window.localStorage.setItem(layoutStorageKey, JSON.stringify(event.api.toJSON())));
  };

  return <main className="workstation"><ConsoleHeader onPalette={() => setPaletteOpen(true)} /><div className="workspace-frame dockview-theme-abyss"><DockviewReact className="dockview-host" components={{ panel: DockPanel }} onReady={onReady} /></div>{paletteOpen && <CommandPalette api={apiRef.current} onClose={() => setPaletteOpen(false)} />}</main>;
}

export default function App(): ReactElement {
  return <Workstation />;
}
