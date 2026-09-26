import { readFileSync } from 'node:fs';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { RuntimeStreamClient, type LiveSnapshot } from '../src/runtime/liveStream';

// Runtime payloads come from goldens produced by the real G5 runtime; only the
// SSE framing around them is scripted here to exercise hostile conditions.
const golden = readFileSync(new URL('./fixtures/runtime-events.failure.v1.ndjson', import.meta.url), 'utf8').trim().split('\n');
const hello = (streamId: string, replay = 'full', extra: Record<string, unknown> = {}) =>
  `event: hello\ndata: ${JSON.stringify({ protocol: 'horizon.runtime-stream.v1', schema: 'horizon.runtime-event.v1', streamId, lastSeq: 0, replay, truncated: false, ...extra })}\n\n`;
const runtime = (streamId: string, line: string) => `id: ${streamId}:${JSON.parse(line).seq}\nevent: runtime\ndata: ${line}\n\n`;
const sseHeaders = { 'content-type': 'text/event-stream', 'cache-control': 'no-store' };

type Handler = (req: IncomingMessage, res: ServerResponse, attempt: number) => void;

let servers: Server[] = [];
let clients: RuntimeStreamClient[] = [];

async function serve(handler: Handler): Promise<{ url: string; requests: IncomingMessage[] }> {
  const requests: IncomingMessage[] = [];
  const server = createServer((req, res) => {
    requests.push(req);
    handler(req, res, requests.length);
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return { url: `http://127.0.0.1:${port}/v1/runtime-events`, requests };
}

function client(url: string, heartbeatTimeoutMs = 2000): { client: RuntimeStreamClient; seen: LiveSnapshot[] } {
  const seen: LiveSnapshot[] = [];
  const c = new RuntimeStreamClient({ url, onChange: (s) => seen.push(s), heartbeatTimeoutMs, reconnectDelayMs: 30 });
  clients.push(c);
  c.start();
  return { client: c, seen };
}

async function until(read: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!read()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

const unknownState = (s: LiveSnapshot) =>
  [s.view.sessionState, s.view.captionEnvironment, s.view.captionTruth, s.view.deviceState].every((v) => v === 'UNKNOWN');

afterEach(async () => {
  clients.forEach((c) => c.stop());
  clients = [];
  await Promise.all(servers.map((s) => new Promise<void>((r) => { s.closeAllConnections(); s.close(() => r()); })));
  servers = [];
});

describe('live runtime stream (fail closed)', () => {
  it('runtime unavailable: UNAVAILABLE with UNKNOWN state, then LIVE once it answers', async () => {
    const { url } = await serve((_req, res, attempt) => {
      if (attempt === 1) { res.writeHead(503); res.end(); return; }
      res.writeHead(200, sseHeaders);
      res.write(hello('S1'));
      golden.forEach((line) => res.write(runtime('S1', line)));
    });
    const { client: c, seen } = client(url);
    await until(() => seen.some((s) => s.connection === 'UNAVAILABLE'), 'UNAVAILABLE');
    const unavailable = seen.find((s) => s.connection === 'UNAVAILABLE')!;
    expect(unavailable.reason).toBe('httpStatus:503');
    expect(unknownState(unavailable)).toBe(true);
    await until(() => c.snapshot().view.sessionState === 'failed', 'live failed session');
    expect(c.snapshot().connection).toBe('LIVE');
    expect(c.snapshot().view.captions).toEqual({ delivered: 1, blocked: 0, failed: 1 });
  });

  it('unreachable host reports UNAVAILABLE, never a state', async () => {
    const probe = createServer();
    await new Promise<void>((r) => probe.listen(0, '127.0.0.1', r));
    const { port } = probe.address() as AddressInfo;
    await new Promise<void>((r) => probe.close(() => r()));
    const { seen } = client(`http://127.0.0.1:${port}/v1/runtime-events`);
    await until(() => seen.some((s) => s.reason === 'unreachable'), 'unreachable');
    expect(seen.every((s) => s.connection !== 'LIVE')).toBe(true);
    expect(seen.every(unknownState)).toBe(true);
  });

  it('disconnect shows DISCONNECTED + UNKNOWN (no stale green), reconnect resumes without duplicates', async () => {
    const { url, requests } = await serve((req, res, attempt) => {
      res.writeHead(200, sseHeaders);
      if (attempt === 1) {
        res.write(hello('S1'));
        golden.slice(0, 5).forEach((line) => res.write(runtime('S1', line)));
        setTimeout(() => res.end(), 50);
        return;
      }
      expect(req.headers['last-event-id']).toBe('S1:5');
      res.write(hello('S1', 'resume'));
      golden.slice(4).forEach((line) => res.write(runtime('S1', line))); // seq 5 repeated on purpose
    });
    const { client: c, seen } = client(url);
    await until(() => seen.some((s) => s.connection === 'DISCONNECTED'), 'DISCONNECTED');
    const dropped = seen.find((s) => s.connection === 'DISCONNECTED')!;
    expect(dropped.reason).toBe('streamEnded');
    expect(unknownState(dropped)).toBe(true);
    await until(() => c.snapshot().view.sessionState === 'failed', 'resumed');
    expect(requests).toHaveLength(2);
    expect(c.snapshot().view.captions).toEqual({ delivered: 1, blocked: 0, failed: 1 });
    expect(c.snapshot().view.sequenceGaps).toBe(0);
  });

  it('stale session: a restarted runtime (new stream id) discards the old session', async () => {
    const other = golden.map((line) => line.replace('"session-golden"', '"session-new"')).slice(0, 2);
    const { url } = await serve((_req, res, attempt) => {
      res.writeHead(200, sseHeaders);
      if (attempt === 1) {
        res.write(hello('OLD'));
        golden.forEach((line) => res.write(runtime('OLD', line)));
        setTimeout(() => res.end(), 50);
        return;
      }
      res.write(hello('NEW', 'reset'));
      other.forEach((line) => res.write(runtime('NEW', line)));
    });
    const { client: c } = client(url);
    await until(() => c.snapshot().streamId === 'NEW' && c.snapshot().view.sessionState === 'listening', 'new session');
    expect(c.snapshot().view.sessionId).toBe('session-new');
    expect(c.snapshot().view.captions).toEqual({ delivered: 0, blocked: 0, failed: 0 });
  });

  it('heartbeat from another stream is stale: DISCONNECTED and resynchronise', async () => {
    const { url } = await serve((_req, res, attempt) => {
      res.writeHead(200, sseHeaders);
      res.write(hello(attempt === 1 ? 'S1' : 'S2'));
      if (attempt === 1) res.write(`event: heartbeat\ndata: ${JSON.stringify({ streamId: 'IMPOSTOR', lastSeq: 9 })}\n\n`);
    });
    const { seen } = client(url);
    await until(() => seen.some((s) => s.reason === 'streamChanged'), 'streamChanged');
    expect(unknownState(seen.find((s) => s.reason === 'streamChanged')!)).toBe(true);
  });

  it('malformed events are rejected and flag DEGRADED without inventing state', async () => {
    const { url } = await serve((_req, res) => {
      res.writeHead(200, sseHeaders);
      res.write(hello('S1'));
      res.write(runtime('S1', golden[0]));
      res.write('id: S1:2\nevent: runtime\ndata: {broken\n\n');
      const withText = { ...JSON.parse(golden[1]), seq: 3, text: 'hola' };
      res.write(`id: S1:3\nevent: runtime\ndata: ${JSON.stringify(withText)}\n\n`);
      res.write('event: mystery\ndata: {}\n\n');
    });
    const { client: c } = client(url);
    await until(() => c.snapshot().view.rejectedLines === 3, 'rejections');
    expect(c.snapshot().view.degraded).toBe(true);
    expect(c.snapshot().view.sessionState).toBe('preparing');
  });

  it('unsupported schema or protocol version: UNSUPPORTED, no state, no retry loop', async () => {
    for (const [extra, reason] of [
      [{ schema: 'horizon.runtime-event.v2' }, 'unsupportedSchema'],
      [{ protocol: 'horizon.runtime-stream.v2' }, 'unsupportedProtocol'],
    ] as const) {
      const { url, requests } = await serve((_req, res) => {
        res.writeHead(200, sseHeaders);
        res.write(hello('S1', 'full', extra));
        golden.forEach((line) => res.write(runtime('S1', line)));
      });
      const { client: c, seen } = client(url);
      await until(() => c.snapshot().connection === 'UNSUPPORTED', reason);
      await new Promise((r) => setTimeout(r, 150));
      expect(c.snapshot().reason).toBe(reason);
      expect(requests).toHaveLength(1);
      expect(seen.every(unknownState)).toBe(true);
    }
  });

  it('backlog/slow consumer overflow: DISCONNECTED then resume from Last-Event-ID', async () => {
    const { url, requests } = await serve((req, res, attempt) => {
      res.writeHead(200, sseHeaders);
      if (attempt === 1) {
        res.write(hello('S1'));
        golden.slice(0, 3).forEach((line) => res.write(runtime('S1', line)));
        res.write(`event: overflow\ndata: ${JSON.stringify({ streamId: 'S1', reason: 'slowConsumer' })}\n\n`);
        return;
      }
      expect(req.headers['last-event-id']).toBe('S1:3');
      res.write(hello('S1', 'resume'));
      golden.slice(3).forEach((line) => res.write(runtime('S1', line)));
    });
    const { client: c, seen } = client(url);
    await until(() => seen.some((s) => s.reason === 'overflow'), 'overflow');
    expect(unknownState(seen.find((s) => s.reason === 'overflow')!)).toBe(true);
    await until(() => c.snapshot().view.sessionState === 'failed', 'resumed after overflow');
    expect(requests).toHaveLength(2);
  });

  it('a silent stream times out to DISCONNECTED instead of showing stale LIVE', async () => {
    const { url } = await serve((_req, res) => {
      res.writeHead(200, sseHeaders);
      res.write(hello('S1'));
      golden.forEach((line) => res.write(runtime('S1', line)));
      // then silence: no heartbeat, connection left open
    });
    const { client: c, seen } = client(url, 200);
    await until(() => c.snapshot().connection === 'LIVE' && c.snapshot().view.sessionState === 'failed', 'live');
    await until(() => seen.some((s) => s.reason === 'heartbeatTimeout'), 'heartbeatTimeout');
    expect(unknownState(seen.find((s) => s.reason === 'heartbeatTimeout')!)).toBe(true);
  });
});
