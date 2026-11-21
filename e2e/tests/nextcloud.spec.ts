import { test, expect, request } from '@playwright/test';

const user = process.env.NEXTCLOUD_TEST_USER;
const password = process.env.NEXTCLOUD_TEST_PASSWORD;

test.skip(!user || !password, 'NEXTCLOUD_TEST_USER / NEXTCLOUD_TEST_PASSWORD are not set');

// Logs in as the test account, uploads a small file through the Files app, checks it really arrived
// (WebDAV) and deletes it again, so every run leaves the account as it found it.
test('log in, upload a file and delete it', async ({ page, baseURL }) => {
  const fileName = `e2e-${Date.now()}.txt`;
  const content = `deployed ${new Date().toISOString()}`;
  const dav = await request.newContext({
    baseURL,
    httpCredentials: { username: user!, password: password! },
  });
  const davPath = `/remote.php/dav/files/${encodeURIComponent(user!)}/${fileName}`;

  try {
    await test.step('log in', async () => {
      await page.goto('/login');
      await page.locator('input[name="user"]').fill(user!);
      await page.locator('input[name="password"]').fill(password!);
      await page.locator('button[type="submit"]').click();
      // Fail at once, with the reason, if Nextcloud rejects the login (no account yet, or another password)
      const rejected = page.getByText(/wrong (login|username|account) or password/i);
      const deadline = Date.now() + 30_000;
      // Nextcloud lands on its Dashboard after login (the default app), so any /apps/... page means logged in
      while (!/\/apps\//.test(page.url())) {
        if (await rejected.isVisible()) {
          throw new Error(
            `Nextcloud rejected the login of '${user}': the account does not exist yet or has another password ` +
              '(deploy.yml creates it; run with -e e2e_reset_password=true after changing NEXTCLOUD_TEST_PASSWORD).',
          );
        }
        if (Date.now() > deadline) throw new Error(`The login did not finish; still at ${page.url()}`);
        await page.waitForTimeout(250);
      }
      // open the Files app explicitly and wait for its list (or the empty-folder message) to render
      await page.goto('/apps/files/');
      await expect(page.locator('[data-cy-files-list], .files-list, [data-cy-files-content]').first()).toBeVisible();
    });

    await test.step('upload a file through the Files app', async () => {
      // the Files app keeps a hidden file input; the folder-upload input is the one with webkitdirectory
      await page
        .locator('input[type="file"]:not([webkitdirectory])')
        .first()
        .setInputFiles({ name: fileName, mimeType: 'text/plain', buffer: Buffer.from(content) });
      await expect(
        page.locator(`[data-cy-files-list-row-name="${fileName}"]`).or(page.getByText(fileName, { exact: true })).first(),
      ).toBeVisible();
    });

    await test.step('the file is stored on the server (WebDAV)', async () => {
      await expect
        .poll(async () => (await dav.get(davPath)).status(), { message: 'file not found over WebDAV' })
        .toBe(200);
      expect(await (await dav.get(davPath)).text()).toBe(content);
    });
  } finally {
    await test.step('delete the file', async () => {
      const res = await dav.delete(davPath);
      expect([204, 404]).toContain(res.status());
      await dav.dispose();
    });
  }
});
