import { expect, test } from '@playwright/test';
import { openStudio } from './studioHelpers';

// Twin without WebGL: every component, state and action stays operable.
test.use({ launchOptions: { args: ['--disable-webgl', '--disable-webgl2', '--disable-3d-apis'] } });

test('the twin is fully operable without 3D', async ({ page }) => {
  const { panel, twin } = await openStudio(page);
  await expect(twin.getByText(/3D is not available in this browser \(WebGL\)/)).toBeVisible();
  await expect(twin.locator('[data-testid="halo-twin-canvas"]')).toHaveCount(0);
  await panel.getByRole('button', { name: 'Run on official emulator' }).click();
  await expect(twin.locator('[data-component="display"]')).toHaveAttribute('data-activity', 'showingCaption');
  await twin.locator('[data-component="button"]').click();
  await expect(twin.locator('[data-selected="button"] [data-provenance]')).toHaveAttribute('data-provenance', 'OFFICIAL_LOCATION');
  await expect(twin.locator('[data-segment="CAPTION_DISPLAY"]')).toHaveAttribute('data-active', 'true');
});
