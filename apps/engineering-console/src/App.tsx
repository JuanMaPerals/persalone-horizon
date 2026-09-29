import { type ReactElement } from 'react';
import { HelloHaloPanel } from './components/HelloHaloPanel';

/** Public HORIZON entrypoint: the canonical Studio V2 / Halo Digital Twin. */
export default function App(): ReactElement {
  return (
    <main className="public-studio-shell">
      <HelloHaloPanel />
    </main>
  );
}
