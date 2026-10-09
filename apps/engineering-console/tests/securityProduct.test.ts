import { readFileSync } from 'node:fs';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { SecurityPanel } from '../src/components/SecurityPanel';

describe('HORIZON Security product panel', () => {
  it('fails closed when runtime evidence is absent', () => {
    const html = renderToStaticMarkup(createElement(SecurityPanel));
    expect(html).toContain('Runtime evidence unavailable');
    expect(html).toContain('Authenticated STOP / PANIC');
    expect(html).toContain('LOOPBACK ONLY');
    expect(html).toContain('Fail closed');
    expect(html).toContain('CONTROL NOT CONNECTED');
    expect(html).toContain('UNKNOWN');
    expect(html).not.toContain('CONTROL AUTHENTICATED');
    expect(html).not.toContain('NONE OBSERVED');
  });

  it('uses the shared configurable runtime endpoint', () => {
    const source = readFileSync(new URL('../src/components/SecurityPanel.tsx', import.meta.url), 'utf8');
    expect(source).toContain('runtimeEventsUrl()');
    expect(source).toContain('view?.degraded');
    expect(source).toContain("degraded ? 'PARTIAL'");
  });
});
