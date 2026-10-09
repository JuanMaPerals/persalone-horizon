const defaultRuntimeEventsUrl = 'http://127.0.0.1:47800/v1/runtime-events';

export function runtimeEventsUrl(): string {
  const configured = import.meta.env.VITE_HORIZON_RUNTIME_EVENTS_URL?.trim();
  return configured || defaultRuntimeEventsUrl;
}
