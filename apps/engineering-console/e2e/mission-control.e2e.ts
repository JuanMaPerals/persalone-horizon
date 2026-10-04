import { expect, test } from '@playwright/test';
test('Mission Control navigates product workspaces', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Mission Control' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'HORIZON is one product, not a dashboard collection' })).toBeVisible();
  await page.getByRole('button', { name: /Studio/ }).click();
  await expect(page.getByRole('region', { name: 'Hello Halo', exact: true })).toBeVisible();
  await page.getByRole('button', { name: /Runtime/ }).click();
  await expect(page.getByText(/NO SOURCE|LIVE STREAM|OFFLINE FILE/)).toBeVisible();
  await page.getByRole('button', { name: /Observability/ }).click();
  await expect(page.getByText('Trace duration')).toBeVisible();
  await page.getByRole('button', { name: /Community Lab/ }).click();
  await expect(page.getByRole('heading', { name: 'HALO Community Lab' })).toBeVisible();
});
