// Client for the phone's authenticated remote control channel
// (RemoteControlServer -> RemoteControlGateway, `apps/mobile`, opt-in build).
// It only sends STOP and PANIC; START, language and device changes stay on
// the phone. The token is the per-launch bearer the operator reads with
// `adb run-as`: it is held in memory by the caller, sent only to a loopback
// URL, and never appears in an error, a log or a result.

export const CONTROL_SCHEMA_VERSION = 1;
export const DEFAULT_CONTROL_URL = 'http://127.0.0.1:47801';

/** Actions Studio may ever send. Anything else is refused before any request. */
export const STUDIO_ACTIONS = ['stop', 'panic'] as const;
export type StudioAction = (typeof STUDIO_ACTIONS)[number];

const ACTIONS = ['stop', 'panic', 'deviceDisconnect', 'start', 'languageChange', 'deviceConnect', 'deviceSelect'] as const;
type ControlAction = (typeof ACTIONS)[number];

export const RESULT_CODES = [
  'accepted',
  'deniedByPolicy',
  'duplicate',
  'replayed',
  'expired',
  'notYetValid',
  'staleGeneration',
  'unsupportedSchema',
  'malformed',
  'rateLimited',
  'rejectedByRuntime',
] as const;
export type ResultCode = (typeof RESULT_CODES)[number];

/** Coded failures of the channel itself (never carry request content). */
export const CHANNEL_ERRORS = [
  'unauthorized',
  'controlLocked',
  'hostNotAllowed',
  'originNotAllowed',
  'preflightRefused',
  'methodNotAllowed',
  'notFound',
  'tooLarge',
  'unsupportedMediaType',
  'busy',
  'badRequest',
] as const;
export type ChannelErrorCode = (typeof CHANNEL_ERRORS)[number] | 'notLoopback' | 'unreachable' | 'badResponse' | 'actionNotAllowed';

export class RemoteControlError extends Error {
  constructor(readonly code: ChannelErrorCode) {
    super(code);
    this.name = 'RemoteControlError';
  }
}

export interface ControlStatus {
  readonly sessionGeneration: number;
  readonly enabledActions: readonly StudioAction[];
  /** Phone clock minus Studio clock, estimated at the request midpoint. */
  readonly clockOffsetMicros: number;
}

export interface ControlResult {
  readonly commandId: string | null;
  readonly action: ControlAction | null;
  readonly resultCode: ResultCode;
  readonly sessionGeneration: number;
  readonly observedAtMicros: number;
}

export interface ControlEnvelope {
  readonly schemaVersion: number;
  readonly commandId: string;
  readonly issuedAt: number;
  readonly sessionGeneration: number;
  readonly action: StudioAction;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const isCount = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0;
const exactKeys = (record: Record<string, unknown>, keys: readonly string[]): boolean =>
  Object.keys(record).length === keys.length && keys.every((key) => key in record);
const oneOf = <T extends string>(values: readonly T[], value: unknown): value is T =>
  typeof value === 'string' && (values as readonly string[]).includes(value);

/** Only a loopback http origin (the adb-forwarded port): the token never leaves the computer. */
export function controlBaseUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new RemoteControlError('notLoopback');
  }
  const loopback = url.hostname === '127.0.0.1' || url.hostname === 'localhost' || url.hostname === '[::1]';
  if (url.protocol !== 'http:' || !loopback || url.username !== '' || url.password !== '' || (url.pathname !== '/' && url.pathname !== '') || url.search !== '' || url.hash !== '') {
    throw new RemoteControlError('notLoopback');
  }
  return url;
}

export function parseStatus(raw: unknown, clockOffsetMicros: number): ControlStatus {
  if (!isRecord(raw) || !exactKeys(raw, ['schemaVersion', 'sessionGeneration', 'observedAt', 'enabledActions'])) {
    throw new RemoteControlError('badResponse');
  }
  const actions = raw.enabledActions;
  if (raw.schemaVersion !== CONTROL_SCHEMA_VERSION || !isCount(raw.sessionGeneration) || !isCount(raw.observedAt) || !Array.isArray(actions) || !actions.every((a) => oneOf(ACTIONS, a))) {
    throw new RemoteControlError('badResponse');
  }
  // Studio never offers an action it does not own, whatever the phone enables.
  const enabled = STUDIO_ACTIONS.filter((action) => actions.includes(action));
  return { sessionGeneration: raw.sessionGeneration, enabledActions: enabled, clockOffsetMicros };
}

export function parseResult(raw: unknown): ControlResult {
  if (!isRecord(raw) || !exactKeys(raw, ['schemaVersion', 'commandId', 'action', 'resultCode', 'sessionGeneration', 'observedAt'])) {
    throw new RemoteControlError('badResponse');
  }
  const { commandId, action, resultCode, sessionGeneration, observedAt } = raw;
  if (
    raw.schemaVersion !== CONTROL_SCHEMA_VERSION ||
    !(commandId === null || (typeof commandId === 'string' && /^[A-Za-z0-9_-]{8,64}$/.test(commandId))) ||
    !(action === null || oneOf(ACTIONS, action)) ||
    !oneOf(RESULT_CODES, resultCode) ||
    !isCount(sessionGeneration) ||
    !isCount(observedAt)
  ) {
    throw new RemoteControlError('badResponse');
  }
  return { commandId, action, resultCode, sessionGeneration, observedAtMicros: observedAt };
}

export function parseChannelError(raw: unknown): ChannelErrorCode {
  return isRecord(raw) && exactKeys(raw, ['error']) && oneOf(CHANNEL_ERRORS, raw.error) ? raw.error : 'badResponse';
}

export function newCommandId(random: (bytes: Uint8Array) => Uint8Array = (b) => crypto.getRandomValues(b)): string {
  const bytes = random(new Uint8Array(12));
  return `studio-${Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')}`;
}

export function buildEnvelope(action: StudioAction, status: ControlStatus, nowMicros: number, commandId: string): ControlEnvelope {
  if (!STUDIO_ACTIONS.includes(action)) throw new RemoteControlError('actionNotAllowed');
  return {
    schemaVersion: CONTROL_SCHEMA_VERSION,
    commandId,
    issuedAt: Math.round(nowMicros + status.clockOffsetMicros),
    sessionGeneration: status.sessionGeneration,
    action,
  };
}

export interface RemoteControlClientOptions {
  readonly baseUrl: string;
  readonly token: string;
  readonly fetchImpl?: typeof fetch;
  readonly nowMicros?: () => number;
  readonly commandId?: () => string;
}

export class RemoteControlClient {
  private readonly base: URL;
  private readonly token: string;
  private readonly fetchImpl: typeof fetch;
  private readonly nowMicros: () => number;
  private readonly commandId: () => string;

  constructor(options: RemoteControlClientOptions) {
    this.base = controlBaseUrl(options.baseUrl);
    this.token = options.token;
    this.fetchImpl = options.fetchImpl ?? fetch.bind(globalThis);
    this.nowMicros = options.nowMicros ?? (() => Date.now() * 1000);
    this.commandId = options.commandId ?? (() => newCommandId());
  }

  async status(): Promise<ControlStatus> {
    const sentAt = this.nowMicros();
    const body = await this.request('GET', '/v1/control/status');
    const receivedAt = this.nowMicros();
    const observedAt = isRecord(body) ? body.observedAt : undefined;
    const offset = isCount(observedAt) ? observedAt - (sentAt + receivedAt) / 2 : 0;
    return parseStatus(body, offset);
  }

  /** One attempt; a network failure is reported, never retried with a new id. */
  async send(action: StudioAction, status: ControlStatus): Promise<ControlResult> {
    if (!status.enabledActions.includes(action)) throw new RemoteControlError('actionNotAllowed');
    const envelope = buildEnvelope(action, status, this.nowMicros(), this.commandId());
    return parseResult(await this.request('POST', '/v1/control/commands', envelope));
  }

  private async request(method: 'GET' | 'POST', path: string, body?: ControlEnvelope): Promise<unknown> {
    let response: Response;
    try {
      response = await this.fetchImpl(new URL(path, this.base).toString(), {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          ...(body === undefined ? {} : { 'content-type': 'application/json' }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
      });
    } catch {
      throw new RemoteControlError('unreachable');
    }
    let payload: unknown;
    try {
      payload = await response.json();
    } catch {
      throw new RemoteControlError('badResponse');
    }
    if (!response.ok) throw new RemoteControlError(parseChannelError(payload));
    return payload;
  }
}
