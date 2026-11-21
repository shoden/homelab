import { defineConfig } from '@playwright/test';

// Settings come from the environment (the playbook passes them from SecretSpec and the inventory):
//   NEXTCLOUD_URL, NEXTCLOUD_TEST_USER, NEXTCLOUD_TEST_PASSWORD
// Optional: E2E_HEADED=1 opens a visible browser window; E2E_SLOW_MO=<ms> pauses after each action
// (default 400 ms when headed) so you can follow it.
const baseURL = process.env.NEXTCLOUD_URL;
if (!baseURL) {
  throw new Error('NEXTCLOUD_URL is not set (https://<nextcloud_domain>). Run it through playbooks/e2e.yml.');
}

const headed = !!process.env.E2E_HEADED;
const slowMo = Number(process.env.E2E_SLOW_MO) || (headed ? 400 : 0);
// A headed Chromium on some Linux desktops (seen on Wayland) paints a white window and never answers a click on
// Nextcloud's login page; software rendering avoids it. E2E_BROWSER_ARGS adds more flags (space separated).
const args = headed ? ['--disable-gpu', ...(process.env.E2E_BROWSER_ARGS?.split(' ').filter(Boolean) ?? [])] : [];

export default defineConfig({
  testDir: './tests',
  timeout: 90_000,
  expect: { timeout: 15_000 },
  retries: 0,
  // no HTML report: it would embed the failure snapshot, which contains the typed password
  reporter: [['list']],
  use: {
    baseURL,
    browserName: 'chromium',
    headless: !headed,
    launchOptions: { slowMo, args },
    // A trace would record the typed password, so it stays off; a screenshot is enough to see what went wrong.
    trace: 'off',
    screenshot: 'only-on-failure',
  },
});
