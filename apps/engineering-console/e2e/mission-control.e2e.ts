import { expect, test } from '@playwright/test';

test('HORIZON product home navigates user capabilities', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Good evening.' })).toBeVisible();
  await expect(page.getByText('What do you want to do?')).toBeVisible();
  await expect(page.getByText('Mission Control')).toHaveCount(0);
  await expect(page.getByText('PUBLIC CONSOLE')).toHaveCount(0);

  await page.getByRole('navigation', { name: 'HORIZON navigation' }).getByTitle('My Halo').click();
  await expect(page.getByRole('heading', { name: 'My Halo' })).toBeVisible();
  await expect(page.getByText('Physical Halo not observed')).toBeVisible();
  await page.getByText('Developer emulator tools', { exact: true }).click();
  await expect(page.getByRole('region', { name: 'Hello Halo', exact: true })).toBeVisible();

  await page.getByRole('button', { name: '‹ Home' }).click();
  await page.getByRole('navigation', { name: 'HORIZON navigation' }).getByTitle('Translate').click();
  await expect(page.getByRole('heading', { name: /Translate conversations/ })).toBeVisible();
  await expect(page.locator('.translate-product')).toBeVisible();

  await page.getByRole('button', { name: '‹ Home' }).click();
  await page.getByRole('button', { name: 'Privacy controls' }).click();
  await expect(page.getByRole('heading', { name: 'You decide what HORIZON can use.' })).toBeVisible();
  await expect(page.getByText('Persistent contextual memory')).toBeVisible();
});
