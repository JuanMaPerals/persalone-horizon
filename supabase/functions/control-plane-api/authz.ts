export const WORKSPACE_CLAIM = 'authorized_workspaces';
const WORKSPACE_PATTERN = /^[A-Z_]+$/;

type JwtClaims = Readonly<Record<string, unknown>>;

export interface CallerIdentity {
  readonly subject: string;
  readonly authorizedWorkspaces: ReadonlySet<string>;
}

export type AuthorizationResult =
  | { readonly ok: true; readonly identity: CallerIdentity }
  | { readonly ok: false; readonly status: 401 | 403; readonly code: 'unauthorized' | 'workspace_forbidden' };

function workspaceClaim(value: unknown): readonly string[] | null {
  if (!Array.isArray(value)) return null;
  if (!value.every((item) => typeof item === 'string' && WORKSPACE_PATTERN.test(item))) return null;
  return [...new Set(value)];
}

/**
 * Converts a verified Supabase JWT user into an authorization subject.
 * Only `app_metadata.authorized_workspaces` is trusted; user metadata and request data are ignored.
 */
export function callerIdentityFromVerifiedUser(user: unknown): CallerIdentity | null {
  if (!user || typeof user !== 'object') return null;
  const candidate = user as { id?: unknown; app_metadata?: JwtClaims };
  if (typeof candidate.id !== 'string' || candidate.id.length === 0) return null;
  const workspaces = workspaceClaim(candidate.app_metadata?.[WORKSPACE_CLAIM]);
  if (!workspaces || workspaces.length === 0) return null;
  return { subject: candidate.id, authorizedWorkspaces: new Set(workspaces) };
}

/**
 * Fails closed for malformed, unknown, and unauthorized workspace values.
 */
export function authorizeWorkspace(identity: CallerIdentity | null, requestedWorkspace: unknown): AuthorizationResult {
  if (!identity) return { ok: false, status: 401, code: 'unauthorized' };
  if (typeof requestedWorkspace !== 'string' || !WORKSPACE_PATTERN.test(requestedWorkspace)) {
    return { ok: false, status: 403, code: 'workspace_forbidden' };
  }
  if (!identity.authorizedWorkspaces.has(requestedWorkspace)) {
    return { ok: false, status: 403, code: 'workspace_forbidden' };
  }
  return { ok: true, identity };
}
