import { type Page, expect } from '@playwright/test';

// Shared helpers for the Studio twin E2E specs.
export const out = process.env.HORIZON_STUDIO_E2E_ARTIFACTS ?? 'test-results';
export const EVENTS = 'http://127.0.0.1:47813/v1/runtime-events';
export const longCaption =
  'Hola Halo. Este texto es deliberadamente largo para ocupar dos paginas ' +
  'en la pantalla redonda; el boton muestra la siguiente pagina del caption';

export async function openStudio(page: Page, hash = '') {
  await page.addInitScript(() => window.localStorage.setItem('persalone.studio.locale', 'en'));
  await page.goto(`/${hash}`);
  await page.getByText('Hello Halo (Studio)', { exact: true }).first().click();
  const panel = page.getByRole('region', { name: 'Hello Halo', exact: true });
  await panel.getByLabel('Companion URL (loopback)').fill('http://127.0.0.1:47811');
  await panel.getByLabel('Pairing token').fill('studio-e2e-token');
  await panel.getByRole('button', { name: 'Connect' }).click();
  await panel.getByLabel('App name').fill('Twin E2E');
  await panel.getByRole('button', { name: /Create from template/ }).click();
  await expect(panel.getByText('App digest', { exact: true })).toBeVisible();
  return { panel, twin: page.locator('section.twin') };
}

export async function setLongCaption(page: Page) {
  const panel = page.getByRole('region', { name: 'Hello Halo', exact: true });
  await panel.getByLabel('Caption text').fill(longCaption);
  await panel.getByRole('button', { name: 'Validate and save' }).click();
  await expect(panel.getByText('2 pages on the round display')).toBeVisible();
}

/** Bright pixels in the centre of the 3D canvas (captions are white on black). */
export async function brightPixels(page: Page): Promise<number> {
  return page.locator('[data-testid="halo-twin-canvas"] canvas').evaluate((canvas: HTMLCanvasElement) => {
    const gl = canvas.getContext('webgl2') ?? canvas.getContext('webgl');
    if (!gl) return -1;
    const w = gl.drawingBufferWidth;
    const h = gl.drawingBufferHeight;
    const px = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
    let n = 0;
    for (let y = Math.floor(h * 0.2); y < h * 0.8; y++) {
      for (let x = Math.floor(w * 0.2); x < w * 0.8; x++) {
        const i = (y * w + x) * 4;
        if (px[i] > 200 && px[i + 1] > 200 && px[i + 2] > 200) n++;
      }
    }
    return n;
  });
}

