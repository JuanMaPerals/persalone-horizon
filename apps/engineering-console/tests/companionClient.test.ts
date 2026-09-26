import { describe, expect, it } from 'vitest';
import { CompanionClient, CompanionError } from '../src/studio/companionClient';

type Call = { url: string; init: RequestInit };

function fakeFetch(responses: Response[]): { fetchImpl: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const next = responses.shift();
    if (!next) throw new TypeError('network down');
    return next;
  }) as unknown as typeof fetch;
  return { fetchImpl, calls };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });

describe('CompanionClient', () => {
  it('sends the pairing token and JSON bodies to the Companion', async () => {
    const { fetchImpl, calls } = fakeFetch([json({ projectId: 'p-000000000001' }, 201)]);
    const client = new CompanionClient('http://127.0.0.1:47810', 'tok', fetchImpl);
    await client.updateContent('p-000000000001', { caption: '")os.exit()--', advanceOn: 'double' });
    expect(calls[0].url).toBe('http://127.0.0.1:47810/v1/projects/p-000000000001/content');
    expect(calls[0].init.method).toBe('PUT');
    expect((calls[0].init.headers as Record<string, string>).authorization).toBe('Bearer tok');
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ caption: '")os.exit()--', advanceOn: 'double' });
  });

  it('keeps the Companion error code and params for localisation', async () => {
    const { fetchImpl } = fakeFetch([json({ error: { code: 'emulatorBlocked', params: { reason: 'pythonNotConfigured' } } }, 409)]);
    const client = new CompanionClient('http://127.0.0.1:47810', 'tok', fetchImpl);
    await expect(client.startRun('p-000000000001')).rejects.toMatchObject({
      code: 'emulatorBlocked', params: { reason: 'pythonNotConfigured' }, status: 409,
    });
  });

  it('a network failure is companionUnreachable, never a fake state', async () => {
    const { fetchImpl } = fakeFetch([]);
    const client = new CompanionClient('http://127.0.0.1:47810', 'tok', fetchImpl);
    const error = await client.health().catch((e: unknown) => e);
    expect(error).toBeInstanceOf(CompanionError);
    expect((error as CompanionError).code).toBe('companionUnreachable');
  });

  it('non-JSON errors keep the HTTP status', async () => {
    const { fetchImpl } = fakeFetch([new Response('oops', { status: 502 })]);
    const client = new CompanionClient('http://127.0.0.1:47810', 'tok', fetchImpl);
    await expect(client.health()).rejects.toMatchObject({ code: 'httpError', params: { status: 502 } });
  });

  it('framebuffer and export return bytes with their server hashes', async () => {
    const png = new Uint8Array([137, 80, 78, 71]);
    const { fetchImpl } = fakeFetch([
      new Response(png, { headers: { 'content-type': 'image/png', 'x-frame-sha256': 'abc' } }),
      new Response(new Uint8Array([1, 2]), { headers: { 'x-package-sha256': 'def', 'content-disposition': 'attachment; filename="local.hello-display.x-0.1.0.horizonapp"' } }),
    ]);
    const client = new CompanionClient('http://127.0.0.1:47810', 'tok', fetchImpl);
    const frame = await client.framebuffer('r-000000000001');
    expect(frame.sha256).toBe('abc');
    expect(new Uint8Array(await frame.png.arrayBuffer())).toEqual(png);
    const pkg = await client.exportPackage('p-000000000001');
    expect(pkg.sha256).toBe('def');
    expect(pkg.fileName).toBe('local.hello-display.x-0.1.0.horizonapp');
  });
});
