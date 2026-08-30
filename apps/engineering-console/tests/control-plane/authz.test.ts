import { describe, expect, it } from 'vitest';
import {
  authorizeWorkspace,
  callerIdentityFromVerifiedUser,
  WORKSPACE_CLAIM,
} from '../../../../supabase/functions/control-plane-api/authz';

const haloCaller = callerIdentityFromVerifiedUser({
  id: 'caller-halo-test',
  app_metadata: { [WORKSPACE_CLAIM]: ['HALO'] },
});

describe('control-plane caller workspace authorization', () => {
  it('accepts a verified caller with signed HALO authorization', () => {
    const result = authorizeWorkspace(haloCaller, 'HALO');
    expect(result).toMatchObject({ ok: true });
  });

  it('rejects a valid caller attempting a different known workspace', () => {
    expect(authorizeWorkspace(haloCaller, 'PERSALONE_APP')).toEqual({
      ok: false,
      status: 403,
      code: 'workspace_forbidden',
    });
  });

  it('rejects an unknown workspace and a malformed workspace without privileged access', () => {
    expect(authorizeWorkspace(haloCaller, 'UNKNOWN_WORKSPACE')).toMatchObject({
      ok: false,
      status: 403,
      code: 'workspace_forbidden',
    });
    expect(authorizeWorkspace(haloCaller, 'halo')).toMatchObject({
      ok: false,
      status: 403,
      code: 'workspace_forbidden',
    });
  });

  it('rejects missing, invalid, and unsigned caller authorization metadata', () => {
    expect(authorizeWorkspace(null, 'HALO')).toEqual({
      ok: false,
      status: 401,
      code: 'unauthorized',
    });
    expect(callerIdentityFromVerifiedUser({ id: 'caller', app_metadata: {} })).toBeNull();
    expect(callerIdentityFromVerifiedUser({ id: 'caller', app_metadata: { [WORKSPACE_CLAIM]: ['halo'] } })).toBeNull();
    expect(callerIdentityFromVerifiedUser({ id: 'caller', app_metadata: { [WORKSPACE_CLAIM]: 'HALO' } })).toBeNull();
  });

  it('fails closed when a caller tampers with the body workspace after HALO authorization', () => {
    const originalAuthorization = authorizeWorkspace(haloCaller, 'HALO');
    const tamperedAuthorization = authorizeWorkspace(haloCaller, 'JUANMAPERALS_WEB');
    expect(originalAuthorization).toMatchObject({ ok: true });
    expect(tamperedAuthorization).toEqual({
      ok: false,
      status: 403,
      code: 'workspace_forbidden',
    });
  });
});
