import { useCallback, useState } from 'react';
import { ca, de, it, pt } from './draftMessages';
import { type Catalog, type MessageKey, en, es } from './messages';

export const LOCALES = ['es', 'en', 'de', 'pt', 'it', 'ca'] as const;
export type Locale = (typeof LOCALES)[number];

export const catalogs: Readonly<Record<Locale, Catalog>> = { es, en, de, pt, it, ca };

/** complete: written for the product; draft: unreviewed, shown as such. */
export const catalogStatus: Readonly<Record<Locale, 'complete' | 'draft-unreviewed'>> = {
  es: 'complete',
  en: 'complete',
  de: 'draft-unreviewed',
  pt: 'draft-unreviewed',
  it: 'draft-unreviewed',
  ca: 'draft-unreviewed',
};

export const localeNames: Readonly<Record<Locale, string>> = {
  es: 'Español',
  en: 'English',
  de: 'Deutsch',
  pt: 'Português',
  it: 'Italiano',
  ca: 'Català',
};

const storageKey = 'persalone.studio.locale';

export function isLocale(value: unknown): value is Locale {
  return typeof value === 'string' && (LOCALES as readonly string[]).includes(value);
}

/** Initial locale: saved choice, else the browser language, else English. */
export function initialLocale(saved: string | null, browserLanguages: readonly string[]): Locale {
  if (isLocale(saved)) return saved;
  for (const tag of browserLanguages) {
    const base = tag.toLowerCase().split('-')[0];
    if (isLocale(base)) return base;
  }
  return 'en';
}

export type Params = Readonly<Record<string, string | number>>;

/** Translates a key; `.one/.other` plural keys are chosen from params.count. */
export function translate(locale: Locale, key: MessageKey, params: Params = {}): string {
  const catalog = catalogs[locale];
  const template = catalog[key] ?? en[key];
  return template.replace(/\{(\w+)\}/g, (match, name: string) => {
    const value = params[name];
    if (value === undefined) return match;
    return typeof value === 'number' ? new Intl.NumberFormat(locale).format(value) : value;
  });
}

export function plural(locale: Locale, base: string, count: number, params: Params = {}): string {
  const category = new Intl.PluralRules(locale).select(count) === 'one' ? 'one' : 'other';
  return translate(locale, `${base}.${category}` as MessageKey, { ...params, count });
}

/** Error codes from the Companion are localised; unknown codes stay visible. */
export function errorMessage(locale: Locale, code: string, params: Params = {}): string {
  const key = `error.${code}` as MessageKey;
  return key in en ? translate(locale, key, params) : translate(locale, 'error.generic', { code });
}

function readSaved(): string | null {
  try {
    return window.localStorage.getItem(storageKey);
  } catch {
    return null;
  }
}

export function useLocale(preferred?: Locale): { readonly locale: Locale; readonly setLocale: (l: Locale) => void } {
  const [locale, setState] = useState<Locale>(() =>
    initialLocale(readSaved(), [
      ...(preferred ? [preferred] : []),
      ...(typeof navigator === 'undefined' ? [] : navigator.languages ?? []),
    ]),
  );
  const setLocale = useCallback((next: Locale) => {
    setState(next);
    try {
      window.localStorage.setItem(storageKey, next);
    } catch {
      // Private mode or blocked storage: the choice lasts for this session.
    }
  }, []);
  return { locale, setLocale };
}
