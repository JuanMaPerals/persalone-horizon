import { defineConfig } from '@playwright/test';

// Studio V1 UI journey: a real browser drives the Console, which talks to a
// real Companion, which drives the official halo-emulator. Requires
// HORIZON_E2E_PYTHON (the emulator venv) and the Dart SDK on PATH.
const python = process.env.HORIZON_E2E_PYTHON ?? '';
const workspace = process.env.HORIZON_STUDIO_E2E_WORKSPACE ?? `${process.env.TMPDIR ?? '/tmp'}/horizon-studio-e2e`;

export default defineConfig({
  testDir: './e2e',
  testMatch: '*.e2e.ts',
  timeout: 120_000,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:5174',
    viewport: { width: 1500, height: 2600 },
    trace: 'retain-on-failure',
  },
  outputDir: process.env.HORIZON_STUDIO_E2E_ARTIFACTS ?? 'test-results',
  webServer: [
    {
      command: `dart run ../companion/bin/horizon_companion.dart --workspace ${workspace} --port 47811 --python ${python} --bridge ../../tooling/e2e/halo_emulator_bridge.py --allow-origin http://127.0.0.1:5174 --token studio-e2e-token`,
      url: 'http://127.0.0.1:47811/v1/health',
      reuseExistingServer: false,
      timeout: 120_000,
    },
    {
      command: 'node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5174 --strictPort',
      url: 'http://127.0.0.1:5174',
      reuseExistingServer: false,
      timeout: 60_000,
    },
  ],
});
