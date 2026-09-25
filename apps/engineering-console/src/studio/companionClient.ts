// Client for the local Studio Companion API /v1 (apps/companion). Studio
// never talks to the emulator or device directly: every action goes through
// the Companion, which owns app runs. Errors keep the Companion's stable code
// so the UI can localise them; network failure is its own code.

export type ComponentState = 'READY' | 'STARTING' | 'DEGRADED' | 'BLOCKED' | 'STOPPED';
export type Gesture = 'single' | 'double' | 'long';
export type Outcome = 'PASS' | 'FAIL' | 'BLOCKED' | 'SKIPPED' | 'CANCELLED';

export interface Health {
  readonly status: 'READY' | 'DEGRADED';
  readonly companionVersion: string;
  readonly components: Readonly<Record<string, { readonly state: ComponentState; readonly reason?: string }>>;
}

export interface Preview {
  readonly pageCount: number;
  readonly pages: readonly (readonly string[])[];
  readonly normalisedChars: number;
  readonly foldedGlyphs: number;
  readonly replacedGlyphs: number;
  readonly noLoss: boolean;
  readonly maxInputChars: number;
}

export interface Manifest {
  readonly appId: string;
  readonly version: string;
  readonly name: string;
  readonly content: { readonly caption: string; readonly advanceOn: Gesture };
}

export interface ProjectView {
  readonly projectId: string;
  readonly manifest: Manifest;
  readonly appDigest: string;
  readonly preview: Preview;
  readonly latestTest: TestResult | null;
}

export interface Metric {
  readonly name: string;
  readonly unit: string;
  readonly stage: string;
  readonly samples: number;
  readonly latest: number | null;
  readonly p50: number | null;
  readonly p95: number | null;
  readonly availability: 'MEASURED' | 'NOT_AVAILABLE';
}

export interface RunView {
  readonly runId: string;
  readonly state: 'running' | 'stopped' | 'failed';
  readonly stopReason: string | null;
  readonly target: 'EMULATED';
  readonly data: 'SYNTHETIC';
  readonly providers: Readonly<Record<string, string>>;
  readonly page: number;
  readonly pageCount: number;
  readonly advanceOn: Gesture;
  readonly metrics: readonly Metric[];
}

export interface ButtonOutcome {
  readonly deviceReports: readonly string[];
  readonly advanced: boolean;
  readonly page: number;
  readonly pageCount: number;
}

export interface Assertion {
  readonly id: string;
  readonly expected: unknown;
  readonly actual: unknown;
  readonly status: 'PASS' | 'FAIL';
}

export interface TestResult {
  readonly runId: string;
  readonly appDigest: string;
  readonly outcome: Outcome;
  readonly blockedReason: string | null;
  readonly target: 'EMULATED';
  readonly data: { readonly provenance: 'SYNTHETIC' };
  readonly providers: Readonly<Record<string, string>>;
  readonly evidence: 'MEASURED' | 'UNKNOWN';
  readonly durationMs: number;
  readonly assertions: readonly Assertion[];
  readonly metrics: readonly Metric[];
  readonly artifacts: readonly { readonly name: string; readonly sha256: string; readonly bytes: number }[];
}

export interface Frame {
  readonly png: Blob;
  readonly sha256: string;
}

export interface ExportedPackage {
  readonly bytes: Blob;
  readonly sha256: string;
  readonly fileName: string;
}

export class CompanionError extends Error {
  constructor(
    readonly code: string,
    readonly params: Readonly<Record<string, string | number>> = {},
    readonly status = 0,
  ) {
    super(code);
  }
}

export class CompanionClient {
  constructor(
    private readonly baseUrl: string,
    private readonly token: string,
    private readonly fetchImpl: typeof fetch = fetch.bind(globalThis),
  ) {}

  health(): Promise<Health> {
    return this.json('GET', '/v1/health');
  }

  createProject(name: string): Promise<ProjectView> {
    return this.json('POST', '/v1/projects', { template: 'hello-display', name });
  }

  updateContent(projectId: string, content: { caption?: string; advanceOn?: Gesture }): Promise<ProjectView> {
    return this.json('PUT', `/v1/projects/${encodeURIComponent(projectId)}/content`, content);
  }

  startRun(projectId: string): Promise<RunView> {
    return this.json('POST', `/v1/projects/${encodeURIComponent(projectId)}/runs`);
  }

  getRun(runId: string): Promise<RunView> {
    return this.json('GET', `/v1/runs/${encodeURIComponent(runId)}`);
  }

  press(runId: string, gesture: Gesture): Promise<ButtonOutcome> {
    return this.json('POST', `/v1/runs/${encodeURIComponent(runId)}/button`, { gesture });
  }

  stop(runId: string): Promise<RunView> {
    return this.json('POST', `/v1/runs/${encodeURIComponent(runId)}/stop`);
  }

  panic(): Promise<{ readonly stoppedRuns: readonly string[] }> {
    return this.json('POST', '/v1/panic');
  }

  runTests(projectId: string): Promise<TestResult> {
    return this.json('POST', `/v1/projects/${encodeURIComponent(projectId)}/tests`);
  }

  async framebuffer(runId: string): Promise<Frame> {
    const response = await this.send('GET', `/v1/runs/${encodeURIComponent(runId)}/framebuffer`);
    return { png: await response.blob(), sha256: response.headers.get('x-frame-sha256') ?? 'UNKNOWN' };
  }

  async exportPackage(projectId: string): Promise<ExportedPackage> {
    const response = await this.send('POST', `/v1/projects/${encodeURIComponent(projectId)}/export`);
    const disposition = response.headers.get('content-disposition') ?? '';
    const fileName = /filename="([^"]+)"/.exec(disposition)?.[1] ?? 'app.horizonapp';
    return { bytes: await response.blob(), sha256: response.headers.get('x-package-sha256') ?? 'UNKNOWN', fileName };
  }

  private async json<T>(method: string, path: string, body?: unknown): Promise<T> {
    const response = await this.send(method, path, body);
    return (await response.json()) as T;
  }

  private async send(method: string, path: string, body?: unknown): Promise<Response> {
    let response: Response;
    try {
      response = await this.fetchImpl(new URL(path, this.baseUrl).toString(), {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          ...(body === undefined ? {} : { 'content-type': 'application/json' }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: 'no-store',
      });
    } catch {
      throw new CompanionError('companionUnreachable');
    }
    if (!response.ok) {
      let code = 'httpError';
      let params: Record<string, string | number> = { status: response.status };
      try {
        const payload = (await response.json()) as { error?: { code?: unknown; params?: unknown } };
        if (typeof payload.error?.code === 'string') code = payload.error.code;
        if (payload.error?.params && typeof payload.error.params === 'object') {
          params = payload.error.params as Record<string, string | number>;
        }
      } catch {
        // Non-JSON error body: keep the HTTP status as the code's parameter.
      }
      throw new CompanionError(code, params, response.status);
    }
    return response;
  }
}
