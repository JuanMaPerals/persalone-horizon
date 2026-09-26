import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { HelloHaloPanel } from '../src/components/HelloHaloPanel';

describe('Hello Halo panel (first render, not connected)', () => {
  it('renders in Spanish with the connection step and no fake state', () => {
    const html = renderToStaticMarkup(<HelloHaloPanel preferredLocale="es" />);
    expect(html).toContain('lang="es"');
    expect(html).toContain('Token de emparejamiento');
    expect(html).toContain('Sin conectar');
    expect(html).not.toContain('Listo');
  });

  it('renders in English; actions that need a Companion are disabled', () => {
    const html = renderToStaticMarkup(<HelloHaloPanel preferredLocale="en" />);
    expect(html).toContain('Pairing token');
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Connect<\/button>/);
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Create from template/);
  });

  it('offers all six languages and marks drafts', () => {
    const html = renderToStaticMarkup(<HelloHaloPanel preferredLocale="en" />);
    for (const name of ['Español', 'English', 'Deutsch (draft)', 'Português (draft)', 'Italiano (draft)', 'Català (draft)']) {
      expect(html).toContain(name);
    }
  });
});
