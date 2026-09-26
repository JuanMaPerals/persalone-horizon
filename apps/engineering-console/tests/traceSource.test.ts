import { describe, expect, it } from 'vitest';
import { emulatedSessions, emulatedTraceEvents } from '../src/data/emulatedTrace';
import { activeTraceSource } from '../src/types/trace';

describe('trace source truth', () => {
  it('labels the bundled hand-written fixture as SIMULATED, never EMULATED or DEVICE', () => {
    expect(emulatedSessions.map((session) => session.source)).toEqual(['SIMULATED']);
    const visibleText = JSON.stringify([emulatedSessions, emulatedTraceEvents]);
    expect(visibleText).not.toMatch(/Emulated|'emulated'|"emulated"/);
  });

  it('derives the banner from the active session instead of a fixed claim', () => {
    expect(activeTraceSource(emulatedSessions, emulatedSessions[0].id)).toBe('SIMULATED');
    expect(
      activeTraceSource([{ ...emulatedSessions[0], id: 'device-1', source: 'DEVICE' }], 'device-1'),
    ).toBe('DEVICE');
  });

  it('reports UNKNOWN when no session is active', () => {
    expect(activeTraceSource(emulatedSessions, null)).toBe('UNKNOWN');
    expect(activeTraceSource([], 'missing')).toBe('UNKNOWN');
  });
});
