import { describe, expect, it } from 'vitest';

import {
  COMMUNITY_SCENARIO_SCHEMA,
  communityScenarios,
  parseCommunityContribution,
  serializeCommunityContribution,
} from '../src/community/scenarios';

describe('community scenario contract', () => {
  it('round-trips a built-in scenario through the versioned contribution format', () => {
    const source = communityScenarios[0];
    expect(source).toBeDefined();

    const parsed = parseCommunityContribution(serializeCommunityContribution(source!));
    expect(parsed).toEqual(source);
  });

  it('rejects an imported scenario that tries to claim physical evidence', () => {
    const payload = JSON.stringify({
      schema: COMMUNITY_SCENARIO_SCHEMA,
      createdBy: 'HALO Community Lab',
      scenario: {
        ...communityScenarios[0],
        evidence: 'MEASURED',
      },
    });

    expect(() => parseCommunityContribution(payload)).toThrow(/SIMULATED/);
  });

  it('rejects oversized imports before JSON parsing', () => {
    expect(() => parseCommunityContribution('x'.repeat(64_001))).toThrow(/64 KB/);
  });

  it('rejects unsupported schemas', () => {
    const payload = JSON.stringify({
      schema: 'persalone.halo.community-scenario/v999',
      scenario: communityScenarios[0],
    });
    expect(() => parseCommunityContribution(payload)).toThrow(/schema/);
  });
});