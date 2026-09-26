import { describe, expect, it } from 'vitest';
import { LOCALES, catalogStatus, catalogs, errorMessage, initialLocale, plural, translate } from '../src/i18n/i18n';
import { en } from '../src/i18n/messages';

const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

describe('Studio catalogs (es, en, de, pt, it, ca)', () => {
  it('every locale has exactly the English keys, non-empty', () => {
    const keys = Object.keys(en).sort();
    for (const locale of LOCALES) {
      expect(Object.keys(catalogs[locale]).sort(), locale).toEqual(keys);
      for (const key of keys) expect(catalogs[locale][key as keyof typeof en].trim(), `${locale}:${key}`).not.toBe('');
    }
  });

  it('every translation keeps the same placeholders', () => {
    for (const locale of LOCALES) {
      for (const [key, value] of Object.entries(en)) {
        expect(placeholders(catalogs[locale][key as keyof typeof en]), `${locale}:${key}`).toEqual(placeholders(value));
      }
    }
  });

  it('only es and en are declared complete; the rest are unreviewed drafts', () => {
    expect(catalogStatus).toEqual({
      es: 'complete', en: 'complete', de: 'draft-unreviewed', pt: 'draft-unreviewed', it: 'draft-unreviewed', ca: 'draft-unreviewed',
    });
  });

  it('plurals and numbers follow the locale', () => {
    expect(plural('es', 'editor.pages', 1)).toBe('1 página en la pantalla redonda');
    expect(plural('es', 'editor.pages', 2)).toBe('2 páginas en la pantalla redonda');
    expect(plural('en', 'editor.pages', 1)).toBe('1 page on the round display');
    expect(translate('de', 'editor.chars', { count: 1200, max: 400 })).toBe('1.200 von 400 Zeichen');
  });

  it('the Unicode limit is worded as loss, never as support', () => {
    for (const locale of ['es', 'en'] as const) {
      const text = plural(locale, 'editor.glyphsReplaced', 3);
      expect(text).toMatch(/UNICODE/);
      expect(text).toMatch(/\?/);
    }
  });

  it('companion error codes are localised; unknown codes stay visible', () => {
    expect(errorMessage('es', 'emulatorBlocked', { reason: 'pythonNotConfigured' })).toBe('El emulador oficial no está disponible: pythonNotConfigured.');
    expect(errorMessage('en', 'somethingNew')).toBe('Error: somethingNew');
  });

  it('initial locale: saved, then browser, then English', () => {
    expect(initialLocale('ca', ['es-ES'])).toBe('ca');
    expect(initialLocale(null, ['pt-BR', 'en'])).toBe('pt');
    expect(initialLocale('xx', ['ja-JP'])).toBe('en');
  });
});
