import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { TranslatePanel } from '../src/components/TranslatePanel';

describe('HORIZON Translate product panel', () => {
  it('fails closed without a live runtime and preserves the local-consent boundary', () => {
    const html = renderToStaticMarkup(createElement(TranslatePanel));
    expect(html).toContain('Runtime unavailable');
    expect(html).toContain('No verified session');
    expect(html).toContain('Local consent required');
    expect(html).toContain('START is intentionally local-only');
    expect(html).toContain('No transcript or translation text is exposed');
    expect(html).not.toContain('Start translation now');
  });
});
