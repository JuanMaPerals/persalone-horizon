import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { TraceStoreProvider } from './store/TraceStoreContext';
import './styles.css';
import '@xyflow/react/dist/style.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <TraceStoreProvider>
      <App />
    </TraceStoreProvider>
  </StrictMode>,
);
