import { readFileSync } from 'node:fs';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { AccessibilityPanel } from '../src/components/AccessibilityPanel';

describe('HORIZON Accessibility product panel', () => {
  it('fails closed and never promotes software captions to physical Halo evidence', () => {
    const html = renderToStaticMarkup(createElement(AccessibilityPanel));
    expect(html).toContain('Live captions with evidence.');
    expect(html).toContain('No physical claim without HALO_REAL + MEASURED');
    expect(html).toContain('Local control only');
    expect(html).toContain('does not activate sensors');
    expect(html).not.toContain('Physical Halo connected');
  });

  it('reuses configured runtime evidence and fails closed on degraded streams', () => {
    const source = readFileSync(new URL('../src/components/AccessibilityPanel.tsx', import.meta.url), 'utf8');
    expect(source).toContain('runtimeEventsUrl()');
    expect(source).toContain("degraded ? 'PARTIAL'");
    expect(source).toContain('Evidence incomplete; state fails closed');
    expect(source).toContain('counts are not authoritative');
  });
});
