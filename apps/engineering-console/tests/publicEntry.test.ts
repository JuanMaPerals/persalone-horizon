import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import App from '../src/App';

describe('public HORIZON entrypoint', () => {
  it('opens the HORIZON product home instead of the Engineering Console', () => {
    const html = renderToStaticMarkup(createElement(App));
    expect(html).toContain('HORIZON navigation');
    expect(html).toContain('What do you want to do?');
    expect(html).toContain('My Halo');
    expect(html).toContain('Translate');
    expect(html).toContain('Privacy controls');
    expect(html).not.toContain('Mission Control');
    expect(html).not.toContain('PUBLIC CONSOLE');
    expect(html).not.toContain('Mission Control navigates');
    expect(html).toContain('HALO · NOT OBSERVED');
    expect(html).toContain('Physical device not observed');
  });
});
