import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.IDLESCREEN_E2E_PORT ?? 4792);

export default defineConfig({
  testDir: './e2e',
  testMatch: '*.spec.mjs',
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: 'line',
  outputDir: './test-results',
  use: { baseURL: `http://127.0.0.1:${port}` },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
  webServer: {
    command: 'node e2e/serve.mjs',
    url: `http://127.0.0.1:${port}/`,
    env: { PORT: String(port) },
    reuseExistingServer: false,
  },
});
