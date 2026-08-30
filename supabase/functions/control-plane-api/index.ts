import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { authorizeWorkspace, callerIdentityFromVerifiedUser } from './authz.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const PLATFORM_SECRET_KEYS = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>;
const SERVICE_ROLE_KEY = PLATFORM_SECRET_KEYS.default
  ?? PLATFORM_SECRET_KEYS.agent_bridge_dispatch
  ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  ?? '';
const privilegedDb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const WORKSPACE = /^[A-Z_]+$/;

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

function error(code: string, status: 400 | 401 | 403 | 404) {
  return json({ ok: false, error: { code } }, status);
}

function errorCode(message: string) {
  const known = [
    'workspace_unknown', 'workspace_destination_unverified', 'workspace_message_type_unauthorized',
    'workspace_invalid', 'message_type_invalid', 'idempotency_key_invalid', 'payload_invalid',
    'payload_message_required', 'payload_message_too_large',
  ];
  return known.find((item) => message.includes(item)) ?? 'control_plane_error';
}

function bearerToken(request: Request): string | null {
  const value = request.headers.get('authorization');
  const match = value?.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}

async function authenticateAndAuthorize(request: Request, requestedWorkspace: unknown) {
  const token = bearerToken(request);
  if (!token) return { ok: false as const, response: error('unauthorized', 401) };

  // This client uses the caller bearer token, never the service role, to validate the JWT.
  const callerDb = createClient(SUPABASE_URL, token, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { authorization: `Bearer ${token}` } },
  });
  const { data, error: authError } = await callerDb.auth.getUser(token);
  if (authError || !data.user) return { ok: false as const, response: error('unauthorized', 401) };

  const authorization = authorizeWorkspace(callerIdentityFromVerifiedUser(data.user), requestedWorkspace);
  if (!authorization.ok) return { ok: false as const, response: error(authorization.code, authorization.status) };

  // The caller has been authenticated and authorized before any service-role database operation.
  const { data: workspace, error: workspaceError } = await privilegedDb
    .schema('agent_bridge')
    .from('projects')
    .select('slug')
    .eq('slug', requestedWorkspace)
    .limit(1)
    .maybeSingle();
  if (workspaceError || !workspace) return { ok: false as const, response: error('workspace_forbidden', 403) };

  return { ok: true as const, subject: authorization.identity.subject };
}

Deno.serve(async (request) => {
  const url = new URL(request.url);

  if (request.method === 'POST' && url.pathname.endsWith('/send-job')) {
    let body: { workspace?: string; message_type?: string; payload?: Record<string, unknown>; idempotency_key?: string; correlation_id?: string };
    try {
      body = await request.json();
    } catch {
      return error('invalid_json', 400);
    }

    const caller = await authenticateAndAuthorize(request, body.workspace);
    if (!caller.ok) return caller.response;
    if (body.correlation_id && !UUID.test(body.correlation_id)) return error('correlation_id_invalid', 400);

    const { data, error: rpcError } = await privilegedDb.rpc('halo_control_plane_send_job', {
      p_workspace: body.workspace ?? null,
      p_message_type: body.message_type ?? null,
      p_payload: body.payload ?? null,
      p_idempotency_key: body.idempotency_key ?? null,
      p_correlation_id: body.correlation_id ?? null,
    });
    if (rpcError) {
      const code = errorCode(rpcError.message);
      const status = ['workspace_unknown', 'workspace_destination_unverified', 'workspace_message_type_unauthorized'].includes(code) ? 409 : 400;
      return error(code, status as 400 | 401 | 403 | 404);
    }
    const job = data?.[0];
    return json({ ok: true, data: { job_id: job.job_id, correlation_id: job.correlation_id, status: job.status, duplicate: job.duplicate } }, job.duplicate ? 200 : 202);
  }

  if (request.method === 'GET' && url.pathname.endsWith('/results')) {
    const workspace = url.searchParams.get('workspace');
    const correlationId = url.searchParams.get('correlation_id');
    const rawLimit = Number(url.searchParams.get('limit') ?? '20');

    const caller = await authenticateAndAuthorize(request, workspace);
    if (!caller.ok) return caller.response;
    if (correlationId && !UUID.test(correlationId)) return error('correlation_id_invalid', 400);

    const { data, error: rpcError } = await privilegedDb.rpc('halo_control_plane_get_results', {
      p_workspace: workspace,
      p_correlation_id: correlationId ?? null,
      p_limit: Number.isFinite(rawLimit) ? rawLimit : 20,
    });
    if (rpcError) return error(errorCode(rpcError.message), 400);
    return json({ ok: true, data: { results: data ?? [] } });
  }

  return error('route_not_found', 404);
});
