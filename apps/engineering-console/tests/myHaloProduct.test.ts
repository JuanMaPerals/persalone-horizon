import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { MyHaloPanel } from '../src/components/MyHaloPanel';
describe('My Halo product panel', () => {
  it('fails closed and never turns prepared/emulated work into a physical claim', () => {
    const html = renderToStaticMarkup(createElement(MyHaloPanel));
    expect(html).toContain('Physical Halo not observed');
    expect(html).toContain('Requires HALO_REAL + MEASURED evidence.');
    expect(html).toContain('VERIFIED IN CI');
    expect(html).toContain('PREPARED');
    expect(html).toContain('does not perform Bluetooth discovery');
    expect(html).toContain('Physical discovery is local-only');
    expect(html).not.toContain('Physical Halo connected');
  });
});
