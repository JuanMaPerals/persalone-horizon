import { createContext, type PropsWithChildren, type ReactElement, useContext, useSyncExternalStore } from 'react';
import { emulatedSessions, emulatedTraceEvents } from '../data/emulatedTrace';
import { HaloTraceStore, type TraceStoreSnapshot } from './traceStore';

const traceStore = new HaloTraceStore(emulatedTraceEvents, emulatedSessions);
const TraceStoreContext = createContext<HaloTraceStore | null>(null);

export function TraceStoreProvider({ children }: PropsWithChildren): ReactElement {
  return <TraceStoreContext.Provider value={traceStore}>{children}</TraceStoreContext.Provider>;
}

export function useTraceStore(): HaloTraceStore {
  const store = useContext(TraceStoreContext);
  if (!store) throw new Error('TraceStoreProvider is required.');
  return store;
}

export function useTraceSnapshot(): TraceStoreSnapshot {
  const store = useTraceStore();
  return useSyncExternalStore(store.subscribe.bind(store), store.getSnapshot, store.getSnapshot);
}
