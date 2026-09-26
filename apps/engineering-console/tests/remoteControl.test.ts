import { readFileSync } from 'node:fs';
import { createServer, type IncomingMessage, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import {
  RESULT_CODES,
  RemoteControlClient,
  RemoteControlError,
  buildEnvelope,
  controlBaseUrl,
  newCommandId,
  parseChannelError,
  parseResult,
  parseStatus,
  type ControlStatus,
  type StudioAction,
} from '../src/runtime/remoteControl';

// Every response shape comes from the real phone-side server
// (packages/translation_runtime/test/remote_control_server_test.dart).
type GoldenLine = { label: string; status: number; body: Record<string, unknown> };
const golden: GoldenLine[] = readFileSync(new URL('./fixtures/control-results.v1.ndjson', import.meta.url), 'utf8')
  .trim()
  .split('\n')
  .map((line) => JSON.parse(line) as GoldenLine);

const token = 'test-token-test-token-test-token';
const status: ControlStatus = { sessionGeneration: 4, enabledActions: ['stop', 'panic'], clockOffsetMicros: 2_500_000 };

describe('control responses from the phone (golden)', () => {
  it('parses the status and every gateway result code', () => {
    const parsed = parseStatus(golden.find((line) => line.label === 'status')!.body, 0);
    expect(parsed).toEqual({ sessionGeneration: 4, enabledActions: ['stop', 'panic'], clockOffsetMicros: 0 });

    const results = golden.filter((line) => line.status === 200 && 'resultCode' in line.body).map((line) => parseResult(line.body));
    expect(new Set(results.map((r) => r.resultCode))).toEqual(new Set(RESULT_CODES));
    expect(results.find((r) => r.commandId === 'golden-start-1')?.resultCode).toBe('deniedByPolicy');
    expect(results.find((r) => r.commandId === 'golden-disc-1')?.resultCode).toBe('deniedByPolicy');
  });

  it('maps every channel refusal to its code, and no response carries a token', () => {
    for (const line of golden.filter((l) => l.status !== 200)) {
      expect(parseChannelError(line.body)).toBe(line.body.error);
    }
    expect(golden.map((l) => l.label)).toEqual(expect.arrayContaining(['unauthorized', 'control-locked', 'host-not-allowed', 'origin-not-allowed', 'too-large']));
    expect(JSON.stringify(golden)).not.toMatch(/bearer|token/i);
  });
});

describe('strict parsing (fail closed)', () => {
  const ok = golden.find((line) => line.label === 'accepted-panic')!.body;

  it('refuses hostile or drifted results', () => {
    for (const hostile of [
      { ...ok, extra: 1 },
      { ...ok, resultCode: 'executed' },
      { ...ok, resultCode: 'ACCEPTED' },
      { ...ok, commandId: 'x' },
      { ...ok, action: 'shell' },
      { ...ok, schemaVersion: 2 },
      { ...ok, sessionGeneration: -1 },
      [ok],
      null,
    ]) {
      expect(() => parseResult(hostile)).toThrowError(RemoteControlError);
    }
  });

  it('never offers an action Studio does not own, whatever the phone enables', () => {
    const wide = { schemaVersion: 1, sessionGeneration: 1, observedAt: 1, enabledActions: ['start', 'deviceDisconnect', 'panic'] };
    expect(parseStatus(wide, 0).enabledActions).toEqual(['panic']);
    expect(() => parseStatus({ ...wide, enabledActions: ['rm -rf'] }, 0)).toThrowError(RemoteControlError);
    expect(() => parseStatus({ ...wide, token }, 0)).toThrowError(RemoteControlError);
  });

  it('unknown error bodies become badResponse, never free text', () => {
    expect(parseChannelError({ error: 'stack trace here' })).toBe('badResponse');
    expect(parseChannelError({ error: 'unauthorized', detail: 'x' })).toBe('badResponse');
  });
});

describe('envelope', () => {
  it('has exactly the five contract fields, clock-corrected', () => {
    const envelope = buildEnvelope('stop', status, 1_000_000, 'studio-0123456789ab');
    expect(Object.keys(envelope).sort()).toEqual(['action', 'commandId', 'issuedAt', 'schemaVersion', 'sessionGeneration']);
    expect(envelope).toEqual({ schemaVersion: 1, commandId: 'studio-0123456789ab', issuedAt: 3_500_000, sessionGeneration: 4, action: 'stop' });
  });

  it('refuses START and anything outside STOP/PANIC before any request', () => {
    for (const action of ['start', 'languageChange', 'deviceDisconnect', 'deviceSelect']) {
      expect(() => buildEnvelope(action as StudioAction, status, 0, 'studio-0123456789ab')).toThrowError(RemoteControlError);
    }
  });

  it('command ids are random and match the contract', () => {
    const a = newCommandId();
    expect(a).toMatch(/^studio-[0-9a-f]{24}$/);
    expect(newCommandId()).not.toBe(a);
  });
});

describe('loopback only: the token never leaves the computer', () => {
  it('refuses any non-loopback or non-plain URL', () => {
    for (const url of ['https://127.0.0.1:47801', 'http://192.168.1.20:47801', 'http://evil.example:47801', 'http://user:pw@127.0.0.1:47801', 'http://127.0.0.1:47801/v1', 'http://127.0.0.1:47801?x=1', 'not a url']) {
      expect(() => controlBaseUrl(url), url).toThrowError(RemoteControlError);
    }
    expect(controlBaseUrl('http://localhost:47801').port).toBe('47801');
  });

  it('a client for a remote host is never built, so nothing is sent', () => {
    let calls = 0;
    const fetchImpl = (async () => {
      calls++;
      return new Response('{}');
    }) as typeof fetch;
    expect(() => new RemoteControlClient({ baseUrl: 'http://10.0.0.5:47801', token, fetchImpl })).toThrowError(RemoteControlError);
    expect(calls).toBe(0);
  });
});

describe('client against a local server', () => {
  let servers: Server[] = [];
  afterEach(async () => {
    await Promise.all(servers.map((s) => new Promise<void>((resolve) => s.close(() => resolve()))));
    servers = [];
  });

  async function serve(reply: (req: IncomingMessage, body: string) => [number, unknown]): Promise<{ url: string; seen: { req: IncomingMessage; body: string }[] }> {
    const seen: { req: IncomingMessage; body: string }[] = [];
    const server = createServer((req, res) => {
      let body = '';
      req.on('data', (chunk: Buffer) => (body += chunk.toString()));
      req.on('end', () => {
        seen.push({ req, body });
        const [code, payload] = reply(req, body);
        res.writeHead(code, { 'content-type': 'application/json' });
        res.end(JSON.stringify(payload));
      });
    });
    servers.push(server);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, seen };
  }

  it('authenticates, corrects the clock and sends the exact envelope', async () => {
    const { url, seen } = await serve((req, body) =>
      req.url === '/v1/control/status'
        ? [200, { schemaVersion: 1, sessionGeneration: 9, observedAt: 5_000_000, enabledActions: ['stop', 'panic'] }]
        : [200, { schemaVersion: 1, commandId: JSON.parse(body).commandId, action: 'panic', resultCode: 'accepted', sessionGeneration: 9, observedAt: 5_000_001 }],
    );
    let now = 1_000_000;
    const client = new RemoteControlClient({ baseUrl: url, token, nowMicros: () => now, commandId: () => 'studio-aaaaaaaaaaaa' });
    const current = await client.status();
    expect(current.sessionGeneration).toBe(9);
    expect(current.clockOffsetMicros).toBe(4_000_000);
    now = 2_000_000;
    const result = await client.send('panic', current);
    expect(result.resultCode).toBe('accepted');

    expect(seen.map((s) => s.req.headers.authorization)).toEqual([`Bearer ${token}`, `Bearer ${token}`]);
    expect(seen[1].req.method).toBe('POST');
    expect(seen[1].req.headers['content-type']).toBe('application/json');
    expect(JSON.parse(seen[1].body)).toEqual({ schemaVersion: 1, commandId: 'studio-aaaaaaaaaaaa', issuedAt: 6_000_000, sessionGeneration: 9, action: 'panic' });
  });

  it('refusals are coded and never echo the token', async () => {
    const { url } = await serve(() => [401, { error: 'unauthorized' }]);
    const client = new RemoteControlClient({ baseUrl: url, token });
    const error = await client.status().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(RemoteControlError);
    expect((error as RemoteControlError).code).toBe('unauthorized');
    expect(String(error)).not.toContain(token);
    expect(JSON.stringify(error)).not.toContain(token);
  });

  it('an action the phone did not enable is never sent', async () => {
    const { url, seen } = await serve(() => [200, {}]);
    const client = new RemoteControlClient({ baseUrl: url, token });
    await expect(client.send('stop', { ...status, enabledActions: ['panic'] })).rejects.toMatchObject({ code: 'actionNotAllowed' });
    expect(seen).toHaveLength(0);
  });

  it('an unreachable phone is its own code', async () => {
    const client = new RemoteControlClient({ baseUrl: 'http://127.0.0.1:9', token });
    await expect(client.status()).rejects.toMatchObject({ code: 'unreachable' });
  });
});
