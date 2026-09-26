// Test tooling only: lets Node (--experimental-strip-types) load the Console's
// TypeScript modules, which import siblings without a file extension.
import { register } from 'node:module';

register(
  'data:text/javascript,' +
    encodeURIComponent(`
export async function resolve(specifier, context, next) {
  try {
    return await next(specifier, context);
  } catch (error) {
    if (specifier.startsWith('.') && !specifier.endsWith('.ts')) {
      return next(specifier + '.ts', context);
    }
    throw error;
  }
}`),
  import.meta.url,
);
