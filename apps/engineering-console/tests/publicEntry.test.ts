import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import App from '../src/App';

describe('public HORIZON entrypoint', () => {
  it('opens the canonical Studio directly instead of the legacy Engineering Console workspace', () => {
    const html = renderToStaticMarkup(createElement(App));
    expect(html).toContain('HORIZON workspaces');
    expect(html).toContain('Mission Control');
    expect(html).toContain('Hello Halo');
    expect(html).not.toContain('Engineering Console V2');
    expect(html).not.toContain('dockview-host');
  });
});
