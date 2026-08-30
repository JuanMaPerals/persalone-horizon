import { describe, expect, it } from 'vitest';
import { emulatedSessions, emulatedTraceEvents } from '../src/data/emulatedTrace';
import { HaloTraceStore } from '../src/store/traceStore';

describe('HaloTraceStore', () => {
  it('orders events and ignores duplicate event identifiers', () => {
    const store = new HaloTraceStore([...emulatedTraceEvents].reverse(), emulatedSessions);
    expect(store.getSnapshot().events[0]?.id).toBe('evt-001');

    store.append([emulatedTraceEvents[0]]);
    expect(store.getSnapshot().events).toHaveLength(emulatedTraceEvents.length);
  });

  it('filters events by normalized text without mutating the stored sequence', () => {
    const store = new HaloTraceStore(emulatedTraceEvents, emulatedSessions);
    store.setSearch('microphone');

    expect(store.visibleEvents().map((event) => event.id)).toEqual(['evt-004']);
    expect(store.getSnapshot().events).toHaveLength(emulatedTraceEvents.length);
  });

  it('updates shared focus from graph selections', () => {
    const store = new HaloTraceStore(emulatedTraceEvents, emulatedSessions);
    store.setFocus({ type: 'graph-node', eventId: 'evt-008' });

    expect(store.selectedEvent()?.kind).toBe('translation.completed');
  });

  it('keeps replay position inside the visible event range and resolves inspector focus', () => {
    const store = new HaloTraceStore(emulatedTraceEvents, emulatedSessions);
    const range = store.timelineRange();

    store.seek(range.end + 5000);
    expect(store.getSnapshot().replay.positionMs).toBe(range.end);
    expect(store.selectedEvent()?.id).toBe('evt-013');

    store.seek(range.start - 5000);
    expect(store.getSnapshot().replay.positionMs).toBe(range.start);
    expect(store.selectedEvent()?.id).toBe('evt-001');
  });
});
