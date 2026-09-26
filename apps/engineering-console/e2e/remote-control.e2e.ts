import { expect, test } from '@playwright/test';

// Studio -> real RemoteControlServer + RemoteControlGateway (Dart fixture,
// STOP and PANIC enabled) in a real browser: CORS preflight, bearer
// authentication and the policy are exercised end to end.
const CONTROL = 'http://127.0.0.1:47821';
const PROBE = 'http://127.0.0.1:47822/commands';
const TOKEN = 'studio-e2e-control-token';

async function openControl(page: import('@playwright/test').Page) {
  await page.addInitScript(() => window.localStorage.setItem('persalone.studio.locale', 'en'));
  await page.goto('/');
  const control = page.getByLabel('Remote control');
  await control.getByLabel('Phone control URL (loopback, via adb forward)').fill(CONTROL);
  return control;
}

async function commands(request: import('@playwright/test').APIRequestContext) {
  return ((await (await request.get(PROBE)).json()) as { commands: { kind: string; origin: string }[] }).commands;
}

test.describe('Studio remote control (authenticated channel)', () => {
  test('without authentication nothing is enabled and nothing is sent', async ({ page, request }) => {
    const before = (await commands(request)).length;
    const control = await openControl(page);
    await expect(control.getByRole('button', { name: 'STOP', exact: true })).toBeDisabled();
    await expect(control.getByRole('button', { name: 'PANIC', exact: true })).toBeDisabled();
    await expect(control.getByRole('button', { name: 'START', exact: true })).toBeDisabled();

    await control.getByLabel('Control token (adb run-as; kept in memory only)').fill('wrong-token');
    await control.getByRole('button', { name: 'Connect control' }).click();
    await expect(control.getByRole('alert')).toHaveText('Control error: unauthorized');
    await expect(control.getByRole('button', { name: 'PANIC', exact: true })).toBeDisabled();
    expect((await commands(request)).length).toBe(before);
  });

  test('authenticated STOP and PANIC reach the runtime as remote; START stays denied', async ({ page, request }) => {
    const before = (await commands(request)).length;
    const control = await openControl(page);
    await control.getByLabel('Control token (adb run-as; kept in memory only)').fill(TOKEN);
    await control.getByRole('button', { name: 'Connect control' }).click();
    await expect(control.getByRole('status')).toContainText('CONTROL AUTHENTICATED');
    await expect(control.getByRole('status')).toContainText('enabled: STOP, PANIC');
    await expect(control.getByRole('button', { name: 'START', exact: true })).toBeDisabled();

    await control.getByRole('button', { name: 'STOP', exact: true }).click();
    await expect(control.getByText('Last command: stop · accepted')).toBeVisible();
    await control.getByRole('button', { name: 'PANIC', exact: true }).click();
    await expect(control.getByText('Last command: panic · accepted')).toBeVisible();

    expect((await commands(request)).slice(before)).toEqual([
      { kind: 'stop', origin: 'remote' },
      { kind: 'panic', origin: 'remote' },
    ]);
    // The token is never rendered back into the page.
    expect(await page.content()).not.toContain(TOKEN);
  });

  test('a non-loopback control URL is refused before any request', async ({ page }) => {
    const control = await openControl(page);
    await control.getByLabel('Phone control URL (loopback, via adb forward)').fill('http://192.168.1.20:47801');
    await control.getByLabel('Control token (adb run-as; kept in memory only)').fill(TOKEN);
    let offLoopback = 0;
    page.on('request', (r) => { if (r.url().startsWith('http://192.168.1.20')) offLoopback++; });
    await control.getByRole('button', { name: 'Connect control' }).click();
    await expect(control.getByRole('alert')).toHaveText('Control error: notLoopback');
    expect(offLoopback).toBe(0);
  });
});
