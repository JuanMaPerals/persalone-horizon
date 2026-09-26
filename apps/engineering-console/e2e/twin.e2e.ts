import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { EVENTS, brightPixels, openStudio, out, setLongCaption } from './studioHelpers';

// V2 gate: the Hello Halo run lives inside the official Halo 3D twin.
// Real browser -> Console -> real Companion -> official halo-emulator, with the
// twin driven by the canonical runtime event stream.
test('twin journey: run -> framebuffer on the 3D Halo -> explode -> button -> page -> Panic', async ({ page }) => {
  const { panel, twin } = await openStudio(page);
  await setLongCaption(page);

  // Official model loaded, validated and rendered; stream LIVE.
  await expect(twin.locator('[data-model-sha]')).toBeVisible({ timeout: 30_000 });
  await expect(twin.locator('[data-connection]')).toHaveAttribute('data-connection', 'LIVE');
  await expect(twin).toHaveAttribute('data-display', 'unknown');
  await twin.getByRole('radio', { name: 'Live framebuffer' }).click();
  await page.waitForTimeout(400);
  const before = await brightPixels(page);
  await twin.locator('[data-testid="halo-twin-canvas"]').screenshot({ path: `${out}/twin-01-before-run.png` });

  // Run: the real framebuffer is projected on the twin's display surface.
  await panel.getByRole('button', { name: 'Run on official emulator' }).click();
  await expect(twin).toHaveAttribute('data-display', 'live');
  await expect(twin.getByText('Live framebuffer from the official emulator on the twin display (page 1 of 2).')).toBeVisible();
  await expect(twin.locator('[data-segment="CAPTION_DISPLAY"]')).toHaveAttribute('data-active', 'true');
  for (const s of ['MIC_STT', 'STT_TRANSLATION', 'TRANSLATION_CAPTION', 'TRANSLATION_TTS', 'TTS_SPEAKER']) {
    await expect(twin.locator(`[data-segment="${s}"]`)).toHaveAttribute('data-active', 'false');
  }
  const display = twin.locator('[data-component="display"]');
  await expect(display).toHaveAttribute('data-environment', 'EMULATED');
  await expect(display).toHaveAttribute('data-activity', 'showingCaption');
  await page.waitForTimeout(400);
  await twin.locator('[data-testid="halo-twin-canvas"]').screenshot({ path: `${out}/twin-02-framebuffer-page1.png` });
  const page1 = await brightPixels(page);
  expect(page1, 'caption pixels on the twin display').toBeGreaterThan(before + 50);

  // Explode, then select the button with the keyboard in the component tree.
  await twin.getByRole('radio', { name: 'Exploded' }).click();
  await expect(twin).toHaveAttribute('data-twin-mode', 'EXPLODED');
  await twin.locator('[data-component="shell"]').focus();
  for (let i = 0; i < 3; i++) await page.keyboard.press('ArrowDown');
  await expect(twin.locator('[data-component="button"]')).toHaveAttribute('aria-pressed', 'true');
  await expect(twin.locator('[data-selected="button"] [data-provenance]')).toHaveAttribute('data-provenance', 'OFFICIAL_LOCATION');
  await expect(twin.locator('[data-selected="button"] [data-activity]')).toHaveAttribute('data-activity', 'noPress');
  await page.waitForTimeout(600);
  await twin.locator('[data-testid="halo-twin-canvas"]').screenshot({ path: `${out}/twin-03-exploded-button-selected.png` });

  // Inject the button from the twin: the device reports it, the page changes.
  await twin.locator('[data-twin-press="single"]').click();
  await expect(twin.locator('[data-selected="button"] [data-activity]')).toHaveAttribute('data-activity', 'lastGesture');
  await expect(twin.locator('[data-selected="button"]')).toContainText('Last press reported by the device: single');
  await expect(twin.getByText('Live framebuffer from the official emulator on the twin display (page 2 of 2).')).toBeVisible();
  await twin.getByRole('radio', { name: 'Live framebuffer' }).click();
  await page.waitForTimeout(500);
  expect(await brightPixels(page)).toBeGreaterThan(before + 50);
  await twin.locator('[data-testid="halo-twin-canvas"]').screenshot({ path: `${out}/twin-04-framebuffer-page2.png` });

  // X-ray and signal flow.
  await twin.getByRole('radio', { name: 'X-ray' }).click();
  await page.waitForTimeout(300);
  await twin.locator('[data-testid="halo-twin-canvas"]').screenshot({ path: `${out}/twin-05-xray.png` });
  await twin.getByRole('radio', { name: 'Signal flow' }).click();
  await page.waitForTimeout(600);
  await twin.locator('[data-testid="halo-twin-canvas"]').screenshot({ path: `${out}/twin-06-signal-flow.png` });
  await twin.getByRole('radio', { name: 'Component state' }).click();
  await expect(twin).toHaveAttribute('data-twin-mode', 'COMPONENT_STATE');

  // Measured rendering performance (this browser, this machine).
  await twin.locator('[data-perf-measure]').click();
  const perf = twin.locator('[data-perf="measured"]');
  await expect(perf).toBeVisible({ timeout: 60_000 });
  const read = async (attr: string) => perf.locator(`[${attr}]`).getAttribute(attr);
  const metrics = {
    loadMs: await twin.locator('[data-load-ms]').getAttribute('data-load-ms'),
    triangles: await read('data-triangles'),
    drawCalls: await read('data-draw-calls'),
    frameMsP50: await read('data-frame-p50'),
    frameMsP95: await read('data-frame-p95'),
    fpsP50: await read('data-fps-p50'),
    fpsP95: await read('data-fps-p95'),
    renderer: await read('data-renderer'),
    modelSha: await twin.locator('[data-model-sha]').getAttribute('data-model-sha'),
  };
  expect(Number(metrics.triangles)).toBeGreaterThan(100_000);
  expect(Number(metrics.fpsP50)).toBeGreaterThan(0);
  writeFileSync(`${out}/twin-performance.json`, JSON.stringify(metrics, null, 2));

  // Panic: every path off, display back to UNKNOWN, stream still LIVE.
  await panel.getByRole('button', { name: 'PANIC' }).click();
  for (const s of ['MIC_STT', 'STT_TRANSLATION', 'TRANSLATION_CAPTION', 'CAPTION_DISPLAY', 'TRANSLATION_TTS', 'TTS_SPEAKER']) {
    await expect(twin.locator(`[data-segment="${s}"]`)).toHaveAttribute('data-active', 'false');
  }
  await expect(twin).toHaveAttribute('data-display', 'unknown');
  await expect(twin.locator('[data-connection]')).toHaveAttribute('data-connection', 'LIVE');
  await expect(twin.locator('[data-component="display"]')).toHaveAttribute('data-activity', 'cleared');
  await twin.getByRole('radio', { name: 'Live framebuffer' }).click();
  await page.waitForTimeout(400);
  expect(await brightPixels(page)).toBeLessThan(before + 50);
  await twin.locator('[data-testid="halo-twin-canvas"]').screenshot({ path: `${out}/twin-07-after-panic.png` });
});

test.describe('twin negatives', () => {
  test('asset missing: 3D refused, the twin keeps working without it', async ({ page }) => {
    await page.route('**/twin/halo.asset.json', (r) => r.fulfill({ status: 404, body: 'missing' }));
    const { twin } = await openStudio(page);
    await expect(twin.locator('[data-asset-error]')).toHaveAttribute('data-asset-error', 'assetMissing');
    await expect(twin.locator('[data-component="button"]')).toBeVisible();
    await expect(twin.locator('[data-testid="halo-twin-canvas"]')).toHaveCount(0);
  });

  test('malformed GLB (matching hash) is rejected before parsing', async ({ page }) => {
    const garbage = Buffer.from('glTF-but-not-really-a-binary-gltf-container');
    const sha = createHash('sha256').update(garbage).digest('hex');
    await page.route('**/twin/halo.asset.json', async (r) => {
      const real = await (await r.fetch()).json();
      await r.fulfill({ json: { ...real, sha256: sha, bytes: garbage.length } });
    });
    await page.route('**/twin/halo.glb', (r) => r.fulfill({ body: garbage, contentType: 'model/gltf-binary' }));
    const { twin } = await openStudio(page);
    await expect(twin.locator('[data-asset-error]')).toHaveAttribute('data-asset-error', 'assetMalformed');
  });

  test('tampered GLB (hash mismatch) is rejected', async ({ page }) => {
    await page.route('**/twin/halo.glb', (r) => r.fulfill({ body: Buffer.alloc(64, 1), contentType: 'model/gltf-binary' }));
    const { twin } = await openStudio(page);
    await expect(twin.locator('[data-asset-error]')).toHaveAttribute('data-asset-error', 'assetHashMismatch');
  });

  test('runtime disconnected: UNKNOWN everywhere, never the last green state', async ({ page }) => {
    await page.route(EVENTS, (r) => r.abort('connectionrefused'));
    const { panel, twin } = await openStudio(page);
    await panel.getByRole('button', { name: 'Run on official emulator' }).click();
    await expect(panel.getByRole('img', { name: /Emulator framebuffer, page 1/ })).toBeVisible();
    await expect(twin.locator('[data-connection]')).toHaveAttribute('data-connection', 'UNAVAILABLE');
    await expect(twin).toHaveAttribute('data-live', 'false');
    await expect(twin).toHaveAttribute('data-display', 'unknown');
    await expect(twin.locator('[data-component="display"]')).toHaveAttribute('data-environment', 'UNKNOWN');
    await expect(twin.locator('[data-segment="CAPTION_DISPLAY"]')).toHaveAttribute('data-active', 'false');
  });

  test('unsupported stream protocol: UNSUPPORTED and UNKNOWN', async ({ page }) => {
    await page.route(EVENTS, (r) => r.fulfill({
      status: 200,
      headers: { 'content-type': 'text/event-stream', 'access-control-allow-origin': 'http://127.0.0.1:5174' },
      body: 'event: hello\ndata: {"protocol":"horizon.runtime-stream.v9","schema":"horizon.runtime-event.v9","streamId":"x","lastSeq":0,"replay":"full","truncated":false}\n\n',
    }));
    const { twin } = await openStudio(page);
    await expect(twin.locator('[data-connection]')).toHaveAttribute('data-connection', 'UNSUPPORTED');
    await expect(twin.locator('[data-component="display"]')).toHaveAttribute('data-environment', 'UNKNOWN');
  });

  test('framebuffer stale: the twin display falls back to UNKNOWN', async ({ page }) => {
    const { panel, twin } = await openStudio(page);
    await setLongCaption(page);
    await panel.getByRole('button', { name: 'Run on official emulator' }).click();
    await expect(twin).toHaveAttribute('data-display', 'live');
    await page.route('**/v1/runs/*/framebuffer', (r) => r.fulfill({ status: 500, body: '{"error":{"code":"internalError","params":{}}}', contentType: 'application/json' }));
    await twin.locator('[data-component="button"]').click();
    await twin.locator('[data-twin-press="single"]').click();
    await expect(twin.locator('[data-component="button"]')).toHaveAttribute('data-activity', 'lastGesture');
    await expect(twin).toHaveAttribute('data-display', 'unknown');
    await expect(twin.getByText('Display UNKNOWN: no live, current framebuffer.')).toBeVisible();
  });

  test('unknown component deep link is reported, not guessed', async ({ page }) => {
    const { twin } = await openStudio(page, '#twin=flux-capacitor');
    await expect(twin.getByRole('alert')).toContainText('Unknown component: flux-capacitor');
    await expect(twin.locator('[aria-pressed="true"]')).toHaveCount(0);
  });

  test('reduced motion is honoured', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    const { twin } = await openStudio(page);
    await expect(twin).toHaveAttribute('data-motion', 'reduced');
    await twin.getByRole('radio', { name: 'Exploded' }).click();
    await expect(twin).toHaveAttribute('data-twin-mode', 'EXPLODED');
  });
});
