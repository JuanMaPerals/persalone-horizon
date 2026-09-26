import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { type Page, expect, test } from '@playwright/test';

// V1 gate: the Hello Halo journey through the existing Console, end to end,
// against the real Companion and the official emulator.
const shots = process.env.HORIZON_STUDIO_E2E_ARTIFACTS ?? 'test-results';
const longCaption =
  'Hola Halo. Este texto es deliberadamente largo para ocupar dos paginas ' +
  'en la pantalla redonda; el boton muestra la siguiente pagina del caption';

/** Screenshot of one journey step (the section under the given heading). */
async function shot(page: Page, name: string, heading: string) {
  const step = page.locator('.studio-step').filter({ has: page.getByRole('heading', { name: heading, exact: true }) });
  await step.scrollIntoViewIfNeeded();
  await step.screenshot({ path: `${shots}/studio-${name}.png` });
}

test('Hello Halo: pair, create, edit, run, button, test, export (en)', async ({ page }) => {
  await page.addInitScript(() => window.localStorage.setItem('persalone.studio.locale', 'en'));
  await page.goto('/');
  await page.getByText('Hello Halo (Studio)', { exact: true }).first().click();
  const panel = page.getByRole('region', { name: 'Hello Halo', exact: true });

  // Pair with the Companion.
  await panel.getByLabel('Companion URL (loopback)').fill('http://127.0.0.1:47811');
  await panel.getByLabel('Pairing token').fill('studio-e2e-token');
  await panel.getByRole('button', { name: 'Connect' }).click();
  await expect(panel.locator('dd[data-state="READY"]').first()).toBeVisible();
  await expect(panel.getByText('Halo hardware')).toBeVisible();
  await shot(page, '01-paired', 'Companion');

  // Create from the template.
  await panel.getByLabel('App name').fill('Hello Halo E2E');
  await panel.getByRole('button', { name: /Create from template/ }).click();
  await expect(panel.getByText('App digest', { exact: true })).toBeVisible();

  // Edit: special characters stay text; the Unicode limit is shown as loss.
  await panel.getByLabel('Caption text').fill('Año 中文 ")os.exit()--');
  await panel.getByRole('button', { name: 'Validate and save' }).click();
  await expect(panel.getByText(/UNICODE LIMIT: 2 characters/)).toBeVisible();
  await expect(panel.getByText(/1 accented character is approximated/)).toBeVisible();
  await shot(page, '02-unicode-limit', 'Caption');

  // Long caption (two pages) advanced by a single press.
  await panel.getByLabel('Caption text').fill(longCaption);
  await panel.getByLabel('Button gesture that shows the next page').selectOption('single');
  await panel.getByRole('button', { name: 'Validate and save' }).click();
  await expect(panel.getByText('2 pages on the round display')).toBeVisible();

  // Run on the official emulator and see the real framebuffer.
  await panel.getByRole('button', { name: 'Run on official emulator' }).click();
  const frame = panel.getByRole('img', { name: 'Emulator framebuffer, page 1 of 2' });
  await expect(frame).toBeVisible();
  await expect(panel.getByText('Official emulator').first()).toBeVisible();
  await shot(page, '03-running-page-1', 'Run');

  // A long press is reported by the device but does not advance.
  await panel.getByRole('button', { name: 'Press: Long press' }).click();
  await expect(panel.getByText(/Device reported: btn:long/)).toBeVisible();
  await expect(panel.getByText('Page unchanged (not the configured gesture).')).toBeVisible();

  // The configured single press shows page 2.
  await panel.getByRole('button', { name: 'Press: Single press' }).click();
  await expect(panel.getByRole('img', { name: 'Emulator framebuffer, page 2 of 2' })).toBeVisible();
  await expect(panel.getByText(/Device reported: btn:single/)).toBeVisible();
  await shot(page, '04-running-page-2', 'Run');

  // Stop.
  await panel.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(panel.getByText(/^Stopped/)).toBeVisible();

  // Tests on the emulator: every assertion passes.
  await panel.getByRole('button', { name: 'Run hello-display tests' }).click();
  const report = panel.locator('.studio-report');
  await expect(report.locator('dd[data-outcome="PASS"]')).toBeVisible({ timeout: 60_000 });
  await expect(report.locator('td[data-outcome="PASS"]')).toHaveCount(9);
  await expect(report.getByText('Synthetic', { exact: true })).toBeVisible();
  await expect(report.getByText('Measured', { exact: true })).toBeVisible();
  await shot(page, '05-test-pass', 'Test');

  // Export and verify the downloaded package against its displayed hash.
  await panel.getByRole('button', { name: 'Export .horizonapp package' }).click();
  const link = panel.getByRole('link', { name: /Download .*\.horizonapp/ });
  await expect(link).toBeVisible();
  const shown = await panel.locator('dt:has-text("Package SHA-256") + dd code').innerText();
  const [download] = await Promise.all([page.waitForEvent('download'), link.click()]);
  const path = await download.path();
  expect(createHash('sha256').update(readFileSync(path)).digest('hex')).toBe(shown);
  await shot(page, '06-exported', 'Export');
});

test('Spanish UI and PANIC', async ({ page }) => {
  await page.addInitScript(() => window.localStorage.setItem('persalone.studio.locale', 'es'));
  await page.goto('/');
  await page.getByText('Hello Halo (Studio)', { exact: true }).first().click();
  const panel = page.getByRole('region', { name: 'Hello Halo', exact: true });
  await panel.getByLabel('URL del Companion (loopback)').fill('http://127.0.0.1:47811');
  await panel.getByLabel('Token de emparejamiento').fill('studio-e2e-token');
  await panel.getByRole('button', { name: 'Conectar' }).click();
  await panel.getByRole('button', { name: /Crear desde la plantilla/ }).click();
  await panel.getByRole('button', { name: 'Ejecutar en el emulador oficial' }).click();
  await expect(panel.getByRole('img', { name: 'Framebuffer del emulador, página 1 de 1' })).toBeVisible();
  await panel.getByRole('button', { name: 'PÁNICO' }).click();
  await expect(panel.getByText(/^Detenida/)).toBeVisible();
  await expect(panel.getByRole('button', { name: 'Pulsar: Pulsación simple' })).toBeDisabled();
  await shot(page, '07-es-panic', 'Ejecución');

  // A wrong token is reported, localised, without inventing a state.
  await panel.getByLabel('Token de emparejamiento').fill('wrong');
  await panel.getByRole('button', { name: 'Conectar' }).click();
  await expect(panel.getByRole('alert')).toHaveText('El token de emparejamiento no es válido.');
});
