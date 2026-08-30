import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const handler = readFileSync(
  fileURLToPath(new URL('../../../../supabase/functions/control-plane-api/index.ts', import.meta.url)),
  'utf8',
);

describe('control-plane handler security contract', () => {
  it('uses the caller bearer token for user validation before checking workspace authorization', () => {
    expect(handler).toContain("const token = bearerToken(request);");
    expect(handler).toContain('const { data, error: authError } = await callerDb.auth.getUser(token);');
    expect(handler).toContain('authorizeWorkspace(callerIdentityFromVerifiedUser(data.user), requestedWorkspace)');
  });

  it('returns 401 for missing or invalid bearer authentication and 403 for forbidden workspaces', () => {
    expect(handler).toContain("if (!token) return { ok: false as const, response: error('unauthorized', 401) };");
    expect(handler).toContain("if (authError || !data.user) return { ok: false as const, response: error('unauthorized', 401) };");
    expect(handler).toContain("response: error(authorization.code, authorization.status)");
    expect(handler).toContain("return { ok: false as const, response: error('workspace_forbidden', 403) };");
  });

  it('authorizes each endpoint before invoking any privileged RPC', () => {
    const sendAuthorization = handler.indexOf('const caller = await authenticateAndAuthorize(request, body.workspace);');
    const sendRpc = handler.indexOf("await privilegedDb.rpc('halo_control_plane_send_job'");
    const resultAuthorization = handler.indexOf('const caller = await authenticateAndAuthorize(request, workspace);');
    const resultRpc = handler.indexOf("await privilegedDb.rpc('halo_control_plane_get_results'");
    expect(sendAuthorization).toBeGreaterThan(-1);
    expect(sendAuthorization).toBeLessThan(sendRpc);
    expect(resultAuthorization).toBeGreaterThan(-1);
    expect(resultAuthorization).toBeLessThan(resultRpc);
  });

  it('does not log bearer tokens, JWT contents, or secrets', () => {
    expect(handler).not.toMatch(/console\.(log|info|warn|error)/);
    expect(handler).not.toContain('Deno.env.get(\'MANUS_API_KEY\')');
  });
});
