import { type ReactElement, useRef, useState } from 'react';
import {
  DEFAULT_CONTROL_URL,
  RemoteControlClient,
  RemoteControlError,
  type ControlResult,
  type ControlStatus,
  type StudioAction,
} from '../runtime/remoteControl';

type Busy = 'status' | 'stop' | null;

const errorCode = (error: unknown): string => (error instanceof RemoteControlError ? error.code : 'unexpected');

/**
 * STOP and PANIC for a phone build that enables the authenticated control
 * channel. The token lives only in the client's memory: the input is
 * uncontrolled (React never mirrors it into a DOM attribute) and is emptied
 * once the client holds it; nothing is stored or logged. START and every
 * other action stay on the phone.
 */
export function RemoteControlPanel(): ReactElement {
  const [url, setUrl] = useState(DEFAULT_CONTROL_URL);
  const tokenInput = useRef<HTMLInputElement>(null);
  const targetRevision = useRef(0);
  const [tokenTyped, setTokenTyped] = useState(false);
  const [client, setClient] = useState<RemoteControlClient | null>(null);
  const [status, setStatus] = useState<ControlStatus | null>(null);
  const [last, setLast] = useState<ControlResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const [panicBusy, setPanicBusy] = useState(false);

  const clearInput = () => {
    if (tokenInput.current) tokenInput.current.value = '';
    setTokenTyped(false);
  };

  const invalidateTarget = () => {
    targetRevision.current += 1;
    setClient(null);
    setStatus(null);
    setLast(null);
    setError(null);
    setBusy(null);
    setPanicBusy(false);
    clearInput();
  };

  const forget = () => invalidateTarget();

  const changeUrl = (value: string) => {
    setUrl(value);
    // The visible target and authenticated target must never diverge.
    invalidateTarget();
  };

  const refresh = async (next: RemoteControlClient, revision = targetRevision.current) => {
    setBusy('status');
    try {
      const nextStatus = await next.status();
      if (revision !== targetRevision.current) return;
      setStatus(nextStatus);
      setClient(next);
      setError(null);
    } catch (caught) {
      if (revision !== targetRevision.current) return;
      setError(errorCode(caught));
      setStatus(null);
      setClient(null);
    } finally {
      if (revision === targetRevision.current) setBusy(null);
    }
  };

  const connect = () => {
    const revision = targetRevision.current + 1;
    targetRevision.current = revision;
    setClient(null);
    setStatus(null);
    setLast(null);
    setError(null);
    setBusy(null);
    setPanicBusy(false);
    try {
      const next = new RemoteControlClient({
        baseUrl: url,
        token: (tokenInput.current?.value ?? '').trim(),
      });
      clearInput();
      void refresh(next, revision);
    } catch (caught) {
      clearInput();
      setError(errorCode(caught));
    }
  };

  const send = async (action: StudioAction) => {
    if (!client || !status) return;
    const revision = targetRevision.current;
    if (action === 'panic') setPanicBusy(true);
    else setBusy('stop');
    try {
      const result = await client.send(action, status);
      if (revision !== targetRevision.current) return;
      setLast(result);
      setError(null);
      // The next command addresses the generation the phone reports now.
      setStatus({ ...status, sessionGeneration: result.sessionGeneration });
    } catch (caught) {
      if (revision !== targetRevision.current) return;
      setError(errorCode(caught));
      if (caught instanceof RemoteControlError && (caught.code === 'unauthorized' || caught.code === 'controlLocked')) {
        forget();
      }
    } finally {
      if (revision === targetRevision.current) {
        if (action === 'panic') setPanicBusy(false);
        else setBusy(null);
      }
    }
  };

  const authenticated = client !== null && status !== null;
  const enabled = (action: StudioAction) =>
    authenticated &&
    status.enabledActions.includes(action) &&
    (action === 'panic' ? !panicBusy : busy === null);

  return <div className="runtime-controls" aria-label="Remote control">
    <div className="runtime-source">
      <label>
        <span>Phone control URL (loopback, via adb forward)</span>
        <input value={url} onChange={(event) => changeUrl(event.target.value)} spellCheck={false} />
      </label>
      <label>
        <span>Control token (adb run-as; kept in memory only)</span>
        <input ref={tokenInput} defaultValue="" onChange={(event) => setTokenTyped(event.target.value.trim() !== '')} type="password" autoComplete="off" spellCheck={false} />
      </label>
      <button type="button" onClick={connect} disabled={busy !== null || panicBusy || !tokenTyped}>Connect control</button>
      <button type="button" onClick={forget} disabled={client === null && !tokenTyped}>Forget token</button>
    </div>
    <p role="status">
      {status
        ? `CONTROL AUTHENTICATED · session generation ${status.sessionGeneration} · enabled: ${status.enabledActions.join(', ').toUpperCase()}`
        : 'CONTROL NOT CONNECTED · Stop and Panic stay on the phone'}
    </p>
    <button type="button" disabled title="Remote START is denied by policy: sessions start on the phone.">START</button>
    <button type="button" disabled={!enabled('stop')} onClick={() => void send('stop')}>STOP</button>
    <button type="button" disabled={!enabled('panic')} onClick={() => void send('panic')}>PANIC</button>
    {client ? <button type="button" disabled={busy !== null || panicBusy} onClick={() => void refresh(client)}>Refresh status</button> : null}
    {last ? <p>Last command: {last.action ?? 'invalid'} · {last.resultCode}</p> : null}
    {error ? <p role="alert">Control error: {error}</p> : null}
    <small>Ordinary requests are time-bounded. PANIC has an independent request state and remains available while STOP or status is pending.</small>
  </div>;
}
