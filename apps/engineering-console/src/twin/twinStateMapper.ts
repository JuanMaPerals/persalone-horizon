// TwinStateMapper: a pure projection of the canonical runtime event stream
// (horizon.runtime-event.v1, parsed by runtime/runtimeEvents.ts and
// delivered by runtime/liveStream.ts) onto twin components and signal-flow
// segments. It owns no state: the same events always give the same twin.
//
// Rules:
// - Not LIVE (connecting, disconnected, unavailable, unsupported) => every
//   component and segment is UNKNOWN/inactive. Never the last green state.
// - Execution environment (SIMULATED/EMULATED/PC_REAL/HALO_REAL/UNKNOWN/
//   BLOCKED) and evidence (PREPARED/MEASURED/HARDWARE_OBSERVED/UNKNOWN) are
//   separate fields, taken only from events that carry them.
// - A segment is active only while the current session is listening and an
//   event of that session proves it; stop, failure or Panic turn it off.
// - Halo microphones/speakers are not claimed by G5 events (G5 captures and
//   speaks on the phone): they stay "no evidence" unless an event names them.
import type { ConnectionState } from '../runtime/liveStream';
import type { ExecutionEnvironment, RuntimeEvent, SessionState, Truth } from '../runtime/runtimeEvents';
import { TWIN_COMPONENTS, type ComponentId } from './components';

export type TwinEnvironment = ExecutionEnvironment | 'UNKNOWN' | 'BLOCKED';
export type TwinEvidence = 'PREPARED' | 'MEASURED' | 'HARDWARE_OBSERVED' | 'UNKNOWN';
export type Activity =
  | 'unknown' | 'showingCaption' | 'cleared' | 'connected' | 'connecting' | 'disconnected'
  | 'lastGesture' | 'noPress' | 'notExercised' | 'failed' | 'blocked';

export interface ComponentState {
  readonly environment: TwinEnvironment;
  readonly evidence: TwinEvidence;
  readonly activity: Activity;
  /** Coded detail (gesture name, reason); never free text. */
  readonly detail: string | null;
  /** Stream sequence of the event behind this state, if any. */
  readonly seq: number | null;
}

export const SEGMENTS = ['MIC_STT', 'STT_TRANSLATION', 'TRANSLATION_CAPTION', 'CAPTION_DISPLAY', 'TRANSLATION_TTS', 'TTS_SPEAKER'] as const;
export type SegmentId = (typeof SEGMENTS)[number];

export interface SegmentState {
  readonly active: boolean;
  /** Event code/kind that proves the segment, when active. */
  readonly proof: string | null;
}

export interface TwinState {
  readonly live: boolean;
  readonly connection: ConnectionState;
  readonly sessionId: string | null;
  readonly sessionState: SessionState | 'UNKNOWN';
  readonly components: Readonly<Record<ComponentId, ComponentState>>;
  readonly segments: Readonly<Record<SegmentId, SegmentState>>;
  /** Caption turns shown in the current session (for framebuffer freshness). */
  readonly captionSeq: number | null;
  /** Events that did not map to any component. */
  readonly unmapped: number;
}

const UNKNOWN: ComponentState = { environment: 'UNKNOWN', evidence: 'UNKNOWN', activity: 'unknown', detail: null, seq: null };
const OFF: SegmentState = { active: false, proof: null };

/**
 * Evidence comes only from the event's own truth label. HARDWARE_OBSERVED is
 * never derived from stream events: it needs a physical observation record.
 */
function evidenceOf(truth: Truth): TwinEvidence {
  if (truth === 'MEASURED') return 'MEASURED';
  if (truth === 'PREPARED' || truth === 'SIMULATED') return 'PREPARED';
  return 'UNKNOWN';
}

function allComponents(state: ComponentState): Record<ComponentId, ComponentState> {
  return Object.fromEntries(TWIN_COMPONENTS.map((c) => [c.id, state])) as Record<ComponentId, ComponentState>;
}

function allSegments(): Record<SegmentId, SegmentState> {
  return Object.fromEntries(SEGMENTS.map((s) => [s, OFF])) as Record<SegmentId, SegmentState>;
}

export function unknownTwin(connection: ConnectionState): TwinState {
  return {
    live: false,
    connection,
    sessionId: null,
    sessionState: 'UNKNOWN',
    components: allComponents(UNKNOWN),
    segments: allSegments(),
    captionSeq: null,
    unmapped: 0,
  };
}

export function mapTwinState(connection: ConnectionState, events: readonly RuntimeEvent[]): TwinState {
  if (connection !== 'LIVE') return unknownTwin(connection);
  const ordered = [...events].sort((a, b) => a.seq - b.seq);
  const components = allComponents({ ...UNKNOWN, activity: 'notExercised' });
  let segments = allSegments();
  let sessionId: string | null = null;
  let sessionState: SessionState | 'UNKNOWN' = 'UNKNOWN';
  let deviceEnv: TwinEnvironment = 'UNKNOWN';
  let deviceEvidence: TwinEvidence = 'UNKNOWN';
  let captionSeq: number | null = null;
  let unmapped = 0;
  let translated = false;

  const set = (id: ComponentId, s: Partial<ComponentState>) => { components[id] = { ...components[id], ...s }; };
  const endSession = () => {
    segments = allSegments();
    translated = false;
  };

  for (const e of ordered) {
    if (e.kind === 'sessionState' && e.session && e.session.id !== sessionId && (e.state === 'preparing' || e.state === 'listening')) {
      // A new session starts: nothing proven by the previous one carries over
      // (the stream may replay older sessions on connect). Session-scoped
      // components restart; the link keeps following its own device events.
      sessionId = e.session.id;
      endSession();
      captionSeq = null;
      const linkKnown = components.mcu.activity === 'connected';
      set('display', { ...UNKNOWN, activity: 'notExercised' });
      set('button', linkKnown
        ? { environment: deviceEnv, evidence: deviceEvidence, activity: 'noPress', detail: null, seq: null }
        : { ...UNKNOWN, activity: 'notExercised' });
    }
    const inCurrent = e.session === null || e.session.id === sessionId;
    switch (e.kind) {
      case 'sessionState': {
        if (!inCurrent) break;
        sessionState = e.state;
        if (e.state !== 'listening' && e.state !== 'preparing') {
          endSession();
          if (components.display.activity === 'showingCaption') set('display', { activity: 'cleared', detail: e.state, seq: e.seq });
        }
        break;
      }
      case 'deviceState': {
        deviceEnv = e.environment;
        deviceEvidence = evidenceOf(e.truth);
        const activity: Activity = e.state === 'ready' ? 'connected'
          : e.state === 'connecting' || e.state === 'discovering' ? 'connecting'
            : e.state === 'failed' ? 'failed' : 'disconnected';
        set('mcu', { environment: e.environment, evidence: deviceEvidence, activity, detail: e.state, seq: e.seq });
        if (activity !== 'connected') {
          set('display', { environment: e.environment, evidence: deviceEvidence, activity: 'cleared', detail: e.state, seq: e.seq });
        }
        if (components.button.activity === 'notExercised') set('button', { environment: e.environment, evidence: deviceEvidence, activity: 'noPress', seq: e.seq });
        break;
      }
      case 'caption': {
        if (!inCurrent) break;
        if (e.status === 'delivered') {
          set('display', { environment: e.environment, evidence: evidenceOf(e.truth), activity: 'showingCaption', detail: e.reason, seq: e.seq });
          captionSeq = e.seq;
          if (sessionState === 'listening' || sessionState === 'preparing') {
            segments = { ...segments, CAPTION_DISPLAY: { active: true, proof: 'caption:delivered' } };
            if (translated) segments = { ...segments, TRANSLATION_CAPTION: { active: true, proof: 'translationCompleted+caption' } };
          }
        } else {
          set('display', { environment: e.status === 'blocked' ? 'BLOCKED' : e.environment, evidence: 'UNKNOWN', activity: e.status === 'blocked' ? 'blocked' : 'failed', detail: e.reason, seq: e.seq });
          segments = { ...segments, CAPTION_DISPLAY: OFF };
        }
        break;
      }
      case 'diagnostic': {
        if (!inCurrent && e.code !== 'panicExecuted') break;
        const live = sessionState === 'listening';
        switch (e.code) {
          case 'transcriptPartial':
          case 'transcriptFinal':
            if (live) segments = { ...segments, MIC_STT: { active: true, proof: e.code } };
            break;
          case 'translationCompleted':
            if (live) {
              translated = true;
              segments = { ...segments, STT_TRANSLATION: { active: true, proof: e.code } };
            }
            break;
          case 'synthesisStarted':
            if (live) segments = { ...segments, TRANSLATION_TTS: { active: true, proof: e.code }, TTS_SPEAKER: { active: true, proof: e.code } };
            break;
          case 'synthesisCompleted':
          case 'synthesisFailed':
            segments = { ...segments, TTS_SPEAKER: OFF };
            break;
          case 'inputButton':
            set('button', { environment: deviceEnv, evidence: deviceEvidence, activity: 'lastGesture', detail: e.detail, seq: e.seq });
            break;
          case 'panicExecuted':
          case 'cleanupFailed':
            endSession();
            break;
          default:
            unmapped += 1;
        }
        break;
      }
      case 'latency':
        break;
    }
  }
  return { live: true, connection, sessionId, sessionState, components, segments, captionSeq, unmapped };
}
