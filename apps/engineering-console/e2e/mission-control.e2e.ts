import { expect, test } from '@playwright/test';

test('HORIZON product home navigates user capabilities', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Good evening.' })).toBeVisible();
  await expect(page.getByText('What do you want to do?')).toBeVisible();
  await expect(page.getByText('Mission Control')).toHaveCount(0);
  await expect(page.getByText('PUBLIC CONSOLE')).toHaveCount(0);

  await page.getByRole('button', { name: 'My Halo', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'My Halo' })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Hello Halo', exact: true })).toBeVisible();

  await page.getByRole('button', { name: '‹ Home' }).click();
  await page.getByRole('button', { name: /Translate/ }).first().click();
  await expect(page.getByRole('heading', { name: 'Translate' })).toBeVisible();
  await expect(page.getByText('Software path ready')).toBeVisible();

  await page.getByRole('button', { name: '‹ Home' }).click();
  await page.getByRole('button', { name: 'Privacy controls' }).click();
  await expect(page.getByRole('heading', { name: 'You decide what HORIZON can use.' })).toBeVisible();
  await expect(page.getByText('Persistent contextual memory')).toBeVisible();
});
