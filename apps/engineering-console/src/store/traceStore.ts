import {
  eventTimeMs,
  type FocusTarget,
  type HaloTraceEvent,
  type ReplayState,
  type TraceDomain,
  type TraceFilters,
  type TraceSession,
  type TraceSeverity,
} from '../types/trace';

export interface TraceStoreSnapshot {
  readonly events: readonly HaloTraceEvent[];
  readonly sessions: readonly TraceSession[];
  readonly activeSessionId: string | null;
  readonly focus: FocusTarget | null;
  readonly filters: TraceFilters;
  readonly replay: ReplayState;
}

type TraceListener = () => void;

const emptyFilters = (): TraceFilters => ({
  text: '',
  domains: new Set<TraceDomain>(),
  severities: new Set<TraceSeverity>(),
});

function ordered(events: readonly HaloTraceEvent[]): readonly HaloTraceEvent[] {
  return [...events].sort((left, right) => {
    const timeDifference = eventTimeMs(left) - eventTimeMs(right);
    return timeDifference === 0 ? left.sequence - right.sequence : timeDifference;
  });
}

function initialReplay(events: readonly HaloTraceEvent[]): ReplayState {
  const first = events[0];
  return { active: false, positionMs: first ? eventTimeMs(first) : 0, speed: 1 };
}

export class HaloTraceStore {
  private listeners = new Set<TraceListener>();
  private snapshot: TraceStoreSnapshot;

  public constructor(events: readonly HaloTraceEvent[], sessions: readonly TraceSession[]) {
    const timeline = ordered(events);
    this.snapshot = {
      events: timeline,
      sessions,
      activeSessionId: sessions[0]?.id ?? null,
      focus: timeline[0] ? { type: 'event', eventId: timeline[0].id } : null,
      filters: emptyFilters(),
      replay: initialReplay(timeline),
    };
  }

  public subscribe(listener: TraceListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  public getSnapshot = (): TraceStoreSnapshot => this.snapshot;

  public append(events: readonly HaloTraceEvent[]): void {
    const existing = new Set(this.snapshot.events.map((event) => event.id));
    const additions = events.filter((event) => !existing.has(event.id));
    if (additions.length === 0) return;
    this.update({ events: ordered([...this.snapshot.events, ...additions]) });
  }

  public selectSession(sessionId: string): void {
    const exists = this.snapshot.sessions.some((session) => session.id === sessionId);
    if (!exists || this.snapshot.activeSessionId === sessionId) return;
    const sessionEvents = this.snapshot.events.filter((event) => event.sessionId === sessionId);
    const first = sessionEvents[0];
    this.update({
      activeSessionId: sessionId,
      focus: first ? { type: 'event', eventId: first.id } : { type: 'session', sessionId },
      replay: {
        ...this.snapshot.replay,
        positionMs: first ? eventTimeMs(first) : this.snapshot.replay.positionMs,
      },
    });
  }

  public setFocus(focus: FocusTarget | null): void {
    this.update({ focus });
  }

  public setSearch(text: string): void {
    this.update({ filters: { ...this.snapshot.filters, text } });
  }

  public toggleDomain(domain: TraceDomain): void {
    const domains = new Set(this.snapshot.filters.domains);
    domains.has(domain) ? domains.delete(domain) : domains.add(domain);
    this.update({ filters: { ...this.snapshot.filters, domains } });
  }

  public toggleSeverity(severity: TraceSeverity): void {
    const severities = new Set(this.snapshot.filters.severities);
    severities.has(severity) ? severities.delete(severity) : severities.add(severity);
    this.update({ filters: { ...this.snapshot.filters, severities } });
  }

  public setReplay(active: boolean): void {
    this.update({ replay: { ...this.snapshot.replay, active } });
  }

  public setReplaySpeed(speed: ReplayState['speed']): void {
    this.update({ replay: { ...this.snapshot.replay, speed } });
  }

  public seek(positionMs: number): void {
    const range = this.timelineRange();
    const bounded = Math.min(Math.max(positionMs, range.start), range.end);
    const nearest = [...this.visibleEvents()]
      .filter((event) => eventTimeMs(event) <= bounded)
      .at(-1);
    this.update({
      replay: { ...this.snapshot.replay, positionMs: bounded },
      focus: nearest ? { type: 'timeline-position', sessionId: nearest.sessionId, positionMs: bounded } : this.snapshot.focus,
    });
  }

  public visibleEvents(): readonly HaloTraceEvent[] {
    const { activeSessionId, filters } = this.snapshot;
    const query = filters.text.trim().toLocaleLowerCase();
    return this.snapshot.events.filter((event) => {
      if (activeSessionId && event.sessionId !== activeSessionId) return false;
      if (filters.domains.size > 0 && !filters.domains.has(event.domain)) return false;
      if (filters.severities.size > 0 && !filters.severities.has(event.severity)) return false;
      if (!query) return true;
      const haystack = [event.title, event.summary, event.kind, event.domain, ...event.tags]
        .join(' ')
        .toLocaleLowerCase();
      return haystack.includes(query);
    });
  }

  public selectedEvent(): HaloTraceEvent | undefined {
    const focus = this.snapshot.focus;
    if (focus?.type === 'event' || focus?.type === 'graph-node') {
      return this.snapshot.events.find((event) => event.id === focus.eventId);
    }
    if (focus?.type === 'timeline-position') {
      return this.snapshot.events
        .filter((event) => event.sessionId === focus.sessionId && eventTimeMs(event) <= focus.positionMs)
        .at(-1);
    }
    return undefined;
  }

  public timelineRange(): { readonly start: number; readonly end: number } {
    const events = this.visibleEvents();
    const first = events[0];
    const last = events.at(-1);
    const fallback = this.snapshot.replay.positionMs;
    return { start: first ? eventTimeMs(first) : fallback, end: last ? eventTimeMs(last) : fallback };
  }

  private update(change: Partial<TraceStoreSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...change };
    this.listeners.forEach((listener) => listener());
  }
}
