// Live, read-only client for the G5 runtime event stream
// (`horizon.runtime-stream.v1` framing over Server-Sent Events). It sends no
// commands. It fails closed: whenever the stream is not LIVE, every runtime
// field is UNKNOWN — the Console never keeps showing the last good state.
import {
  RUNTIME_EVENT_SCHEMA,
  RuntimeEventError,
  parseRuntimeEventLine,
  reduceRuntimeEvents,
  type RuntimeEvent,
  type RuntimeView,
} from './runtimeEvents';

export const RUNTIME_STREAM_PROTOCOL = 'horizon.runtime-stream.v1';

export type ConnectionState = 'IDLE' | 'CONNECTING' | 'LIVE' | 'DISCONNECTED' | 'UNAVAILABLE' | 'UNSUPPORTED';

export interface LiveSnapshot {
  readonly connection: ConnectionState;
  /** Coded cause of the current non-LIVE state. */
  readonly reason: string | null;
  readonly streamId: string | null;
  readonly view: RuntimeView;
  readonly lastSeenSequence: number | null;
  /** Parsed events, only while LIVE (empty otherwise: fail closed). */
  readonly events: readonly RuntimeEvent[];
}

export interface LiveClientOptions {
  readonly url: string;
  readonly onChange: (snapshot: LiveSnapshot) => void;
  readonly fetchImpl?: typeof fetch;
  readonly heartbeatTimeoutMs?: number;
  readonly reconnectDelayMs?: number;
  readonly maxBufferedEvents?: number;
}

const unknownView = reduceRuntimeEvents({ events: [], rejected: [] });

export class RuntimeStreamClient {
  private readonly fetchImpl: typeof fetch;
  private readonly heartbeatTimeoutMs: number;
  private readonly reconnectDelayMs: number;
  private readonly maxBufferedEvents: number;
  private connection: ConnectionState = 'IDLE';
  private reason: string | null = null;
  private streamId: string | null = null;
  private lastEventId: string | null = null;
  private events: RuntimeEvent[] = [];
  private rejected: { line: number; reason: string }[] = [];
  private truncated = false;
  private lastFrameAt = 0;
  private abort: AbortController | null = null;
  private watchdog: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private stopped = true;
  private readonly options: LiveClientOptions;

  constructor(options: LiveClientOptions) {
    this.options = options;
    this.fetchImpl = options.fetchImpl ?? fetch.bind(globalThis);
    this.heartbeatTimeoutMs = options.heartbeatTimeoutMs ?? 3000;
    this.reconnectDelayMs = options.reconnectDelayMs ?? 1000;
    this.maxBufferedEvents = options.maxBufferedEvents ?? 5000;
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.watchdog = setInterval(() => this.checkHeartbeat(), Math.max(50, Math.floor(this.heartbeatTimeoutMs / 3)));
    void this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.watchdog) clearInterval(this.watchdog);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.abort?.abort();
    this.setConnection('IDLE', null);
  }

  snapshot(): LiveSnapshot {
    const live = this.connection === 'LIVE';
    const view = live ? this.reduce() : unknownView;
    return {
      connection: this.connection,
      reason: this.reason,
      streamId: live ? this.streamId : null,
      view,
      lastSeenSequence: this.events.length ? this.events[this.events.length - 1].seq : null,
      events: live ? [...this.events] : [],
    };
  }

  private reduce(): RuntimeView {
    const view = reduceRuntimeEvents({ events: this.events, rejected: this.rejected });
    return this.truncated ? { ...view, degraded: true } : view;
  }

  private setConnection(connection: ConnectionState, reason: string | null): void {
    this.connection = connection;
    this.reason = reason;
    this.options.onChange(this.snapshot());
  }

  private resetState(): void {
    this.events = [];
    this.rejected = [];
    this.truncated = false;
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    this.setConnection('CONNECTING', this.reason);
    const abort = new AbortController();
    this.abort = abort;
    let response: Response;
    try {
      const headers: Record<string, string> = { accept: 'text/event-stream' };
      if (this.lastEventId) headers['last-event-id'] = this.lastEventId;
      response = await this.fetchImpl(this.options.url, { headers, signal: abort.signal, cache: 'no-store' });
    } catch {
      this.disconnected('UNAVAILABLE', 'unreachable');
      return;
    }
    if (!response.ok || !response.body) {
      this.disconnected('UNAVAILABLE', `httpStatus:${response.status}`);
      return;
    }
    if (!(response.headers.get('content-type') ?? '').startsWith('text/event-stream')) {
      this.disconnected('UNAVAILABLE', 'notAnEventStream');
      return;
    }
    this.lastFrameAt = Date.now();
    try {
      await this.read(response.body, abort);
      if (!this.stopped && this.connection !== 'UNSUPPORTED' && !abort.signal.aborted) this.disconnected('DISCONNECTED', 'streamEnded');
    } catch {
      if (!this.stopped && this.connection !== 'UNSUPPORTED' && !abort.signal.aborted) this.disconnected('DISCONNECTED', 'streamError');
    }
  }

  private async read(body: ReadableStream<Uint8Array>, abort: AbortController): Promise<void> {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let event = 'message';
    let id: string | null = null;
    let data = '';
    while (!abort.signal.aborted) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      let newline: number;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline).replace(/\r$/, '');
        buffer = buffer.slice(newline + 1);
        if (line === '') {
          if (data !== '') this.frame(event, id, data, abort);
          event = 'message';
          id = null;
          data = '';
        } else if (line.startsWith('event:')) {
          event = line.slice(6).trim();
        } else if (line.startsWith('id:')) {
          id = line.slice(3).trim();
        } else if (line.startsWith('data:')) {
          data += line.slice(5).replace(/^ /, '');
        }
        if (abort.signal.aborted) return;
      }
    }
  }

  private frame(event: string, id: string | null, data: string, abort: AbortController): void {
    this.lastFrameAt = Date.now();
    let payload: Record<string, unknown> | null = null;
    if (event !== 'runtime') {
      try {
        const parsed: unknown = JSON.parse(data);
        payload = typeof parsed === 'object' && parsed !== null ? (parsed as Record<string, unknown>) : null;
      } catch {
        payload = null;
      }
    }
    switch (event) {
      case 'hello': {
        if (!payload || payload.protocol !== RUNTIME_STREAM_PROTOCOL) return this.unsupported('unsupportedProtocol', abort);
        if (payload.schema !== RUNTIME_EVENT_SCHEMA) return this.unsupported('unsupportedSchema', abort);
        const streamId = typeof payload.streamId === 'string' ? payload.streamId : null;
        if (!streamId) return this.unsupported('invalidHello', abort);
        // Anything but a resume of the same stream discards previous state:
        // a restarted runtime must never inherit the old session.
        if (payload.replay !== 'resume' || streamId !== this.streamId) this.resetState();
        this.truncated = this.truncated || payload.truncated === true;
        this.streamId = streamId;
        this.setConnection('LIVE', null);
        return;
      }
      case 'runtime': {
        if (this.connection !== 'LIVE') return;
        try {
          const parsed = parseRuntimeEventLine(data);
          const last = this.events.length ? this.events[this.events.length - 1].seq : 0;
          if (parsed.seq <= last) return; // replayed duplicate
          this.events.push(parsed);
          if (this.events.length > this.maxBufferedEvents) {
            this.events.shift();
            this.truncated = true;
          }
          if (id && id.startsWith(`${this.streamId}:`)) this.lastEventId = id;
        } catch (error) {
          this.rejected.push({ line: this.rejected.length + 1, reason: error instanceof RuntimeEventError ? error.message : 'invalid event' });
        }
        this.options.onChange(this.snapshot());
        return;
      }
      case 'heartbeat': {
        if (payload?.streamId !== this.streamId) {
          // Frames from another runtime on the same stream are stale.
          this.resetState();
          this.lastEventId = null;
          abort.abort();
          this.disconnected('DISCONNECTED', 'streamChanged');
        }
        return;
      }
      case 'overflow':
        abort.abort();
        this.disconnected('DISCONNECTED', 'overflow', 0);
        return;
      default:
        this.rejected.push({ line: this.rejected.length + 1, reason: `unknown frame ${event}` });
        this.options.onChange(this.snapshot());
    }
  }

  private unsupported(reason: string, abort: AbortController): void {
    abort.abort();
    this.resetState();
    this.lastEventId = null;
    // Requires a Console upgrade; retrying would not help.
    this.setConnection('UNSUPPORTED', reason);
  }

  private checkHeartbeat(): void {
    if (this.connection === 'LIVE' && Date.now() - this.lastFrameAt > this.heartbeatTimeoutMs) {
      this.abort?.abort();
      this.disconnected('DISCONNECTED', 'heartbeatTimeout');
    }
  }

  private disconnected(state: 'DISCONNECTED' | 'UNAVAILABLE', reason: string, delay = this.reconnectDelayMs): void {
    if (this.stopped) return;
    this.setConnection(state, reason);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => void this.connect(), delay);
  }
}
