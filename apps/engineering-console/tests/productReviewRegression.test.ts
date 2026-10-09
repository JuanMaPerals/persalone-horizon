import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

describe('post-review product regressions', () => {
  it('keeps the public shell responsive and navigation glyphs decorative', () => {
    const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
    const app = readFileSync(new URL('../src/App.tsx', import.meta.url), 'utf8');
    expect(css).toContain('min-width: 0');
    expect(css).toContain('.product-content{overflow:auto}');
    expect(app).toContain('aria-label={item.label}');
    expect(app).toContain('aria-hidden="true"');
  });

  it('uses product metadata, not Studio metadata', () => {
    const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
    expect(html).toContain('<title>PersalOne HORIZON</title>');
    expect(html).not.toContain('Halo Digital Twin</title>');
  });

  it('shares a configurable runtime evidence endpoint', () => {
    const endpoint = readFileSync(new URL('../src/runtime/runtimeEndpoint.ts', import.meta.url), 'utf8');
    const translate = readFileSync(new URL('../src/components/TranslatePanel.tsx', import.meta.url), 'utf8');
    const halo = readFileSync(new URL('../src/components/MyHaloPanel.tsx', import.meta.url), 'utf8');
    expect(endpoint).toContain('VITE_HORIZON_RUNTIME_EVENTS_URL');
    expect(translate).toContain('runtimeEventsUrl()');
    expect(halo).toContain('runtimeEventsUrl()');
  });

  it('fails closed when runtime evidence is degraded', () => {
    const translate = readFileSync(new URL('../src/components/TranslatePanel.tsx', import.meta.url), 'utf8');
    const halo = readFileSync(new URL('../src/components/MyHaloPanel.tsx', import.meta.url), 'utf8');
    expect(translate).toContain("degraded ? 'PARTIAL'");
    expect(translate).toContain('Runtime degraded');
    expect(halo).toContain("degraded ? 'DEGRADED'");
    expect(halo).toContain('device-derived values are reported as UNKNOWN');
  });
});
