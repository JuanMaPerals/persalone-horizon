import { type ReactElement, useRef, useState } from 'react';
import {
  DEFAULT_CONTROL_URL,
  RemoteControlClient,
  RemoteControlError,
  type ControlResult,
  type ControlStatus,
  type StudioAction,
} from '../runtime/remoteControl';

type Busy = 'status' | StudioAction | null;

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
  const [tokenTyped, setTokenTyped] = useState(false);
  const [client, setClient] = useState<RemoteControlClient | null>(null);
  const [status, setStatus] = useState<ControlStatus | null>(null);
  const [last, setLast] = useState<ControlResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<Busy>(null);

  const clearInput = () => {
    if (tokenInput.current) tokenInput.current.value = '';
    setTokenTyped(false);
  };

  const forget = () => {
    setClient(null);
    setStatus(null);
    clearInput();
  };

  const refresh = async (next: RemoteControlClient) => {
    setBusy('status');
    try {
      setStatus(await next.status());
      setClient(next);
      setError(null);
    } catch (caught) {
      setError(errorCode(caught));
      setStatus(null);
      setClient(null);
    } finally {
      setBusy(null);
    }
  };

  const connect = () => {
    try {
      const next = new RemoteControlClient({ baseUrl: url, token: (tokenInput.current?.value ?? '').trim() });
      clearInput();
      void refresh(next);
    } catch (caught) {
      setError(errorCode(caught));
    }
  };

  const send = async (action: StudioAction) => {
    if (!client || !status) return;
    setBusy(action);
    try {
      const result = await client.send(action, status);
      setLast(result);
      setError(null);
      // The next command addresses the generation the phone reports now.
      setStatus({ ...status, sessionGeneration: result.sessionGeneration });
    } catch (caught) {
      setError(errorCode(caught));
      if (caught instanceof RemoteControlError && (caught.code === 'unauthorized' || caught.code === 'controlLocked')) forget();
    } finally {
      setBusy(null);
    }
  };

  const ready = client !== null && status !== null && busy === null;
  const enabled = (action: StudioAction) => ready && status.enabledActions.includes(action);

  return <div className="runtime-controls" aria-label="Remote control">
    <div className="runtime-source">
      <label>
        <span>Phone control URL (loopback, via adb forward)</span>
        <input value={url} onChange={(event) => setUrl(event.target.value)} spellCheck={false} />
      </label>
      <label>
        <span>Control token (adb run-as; kept in memory only)</span>
        <input ref={tokenInput} defaultValue="" onChange={(event) => setTokenTyped(event.target.value.trim() !== '')} type="password" autoComplete="off" spellCheck={false} />
      </label>
      <button type="button" onClick={connect} disabled={busy !== null || !tokenTyped}>Connect control</button>
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
    {client ? <button type="button" disabled={busy !== null} onClick={() => void refresh(client)}>Refresh status</button> : null}
    {last ? <p>Last command: {last.action ?? 'invalid'} · {last.resultCode}</p> : null}
    {error ? <p role="alert">Control error: {error}</p> : null}
    <small>Remote START, language and device changes are denied by policy; STOP and PANIC only.</small>
  </div>;
}
