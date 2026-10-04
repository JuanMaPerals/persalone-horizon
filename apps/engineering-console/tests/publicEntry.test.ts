import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import App from '../src/App';

describe('public HORIZON entrypoint', () => {
  it('opens the canonical HORIZON product home instead of the legacy Engineering Console workspace', () => {
    const html = renderToStaticMarkup(createElement(App));
    expect(html).toContain('HORIZON workspaces');
    expect(html).toContain('Mission Control');
    expect(html).toContain('HORIZON is one product, not a dashboard collection');
    expect(html).toContain('Open Studio');
    expect(html).toContain('Privacy');
    expect(html).not.toContain('Engineering Console V2');
    expect(html).not.toContain('dockview-host');
  });
});
