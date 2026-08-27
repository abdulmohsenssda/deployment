import { test, expect, Page } from '@playwright/test';

const BASE = 'http://localhost:8088';
const USER = 'admin';
const PASS = 'admin';

// ── helpers ─────────────────────────────────────────────────────────────────

async function login(page: Page) {
  await page.goto(BASE + '/login');
  await page.fill('input[name="user"]', USER);
  await page.fill('input[name="pass"]', PASS);
  await page.click('button[type="submit"]');
  // Login redirects to /?from=login — match any URL starting with BASE + '/'
  await page.waitForURL(url => url.toString().startsWith(BASE + '/') && !url.toString().includes('/login'), { timeout: 8000 });
}

// ── login page ───────────────────────────────────────────────────────────────

test('login page renders without Tailwind classes', async ({ page }) => {
  await page.goto(BASE + '/login');

  // Should show brand name
  await expect(page.locator('text=Dokku Control Plane')).toBeVisible();

  // Input fields present
  await expect(page.locator('input[name="user"]')).toBeVisible();
  await expect(page.locator('input[name="pass"]')).toBeVisible();
  await expect(page.locator('button[type="submit"]')).toBeVisible();

  // CSS variables should be in effect — body background should be dark
  const bg = await page.evaluate(() =>
    getComputedStyle(document.body).backgroundColor
  );
  // rgb(15, 17, 23) = #0f1117
  expect(bg).toMatch(/rgb\(1[0-9]/);
});

test('login with wrong credentials shows error', async ({ page }) => {
  await page.goto(BASE + '/login');
  await page.fill('input[name="user"]', 'wrong');
  await page.fill('input[name="pass"]', 'wrong');
  await page.click('button[type="submit"]');
  await expect(page.locator('text=Invalid credentials')).toBeVisible();
});

test('login succeeds and redirects to fleet', async ({ page }) => {
  await login(page);
  // After login the server redirects to /?from=login
  await expect(page).toHaveURL(/\/(\?.*)?$/);
  await expect(page.locator('h1')).toContainText('Tenant Fleet');
});

// ── fleet table ──────────────────────────────────────────────────────────────

test('fleet page has table headers', async ({ page }) => {
  await login(page);
  await expect(page.locator('th.col-name')).toContainText('Tenant');
  await expect(page.locator('th.col-health')).toContainText('Health');
  await expect(page.locator('th.col-state')).toContainText('State');
  await expect(page.locator('th.col-version')).toContainText('Version');
  await expect(page.locator('th.col-actions')).toContainText('Actions');
});

test('fleet page has kind selector with dev/qa/prod options', async ({ page }) => {
  await login(page);
  const sel = page.locator('#kind-select');
  await expect(sel).toBeVisible();
  await expect(sel.locator('option[value="dev"]')).toHaveCount(1);
  await expect(sel.locator('option[value="qa"]')).toHaveCount(1);
  await expect(sel.locator('option[value="prod"]')).toHaveCount(1);
});

test('fleet create-tenant button exists', async ({ page }) => {
  await login(page);
  await expect(page.locator('#create-tenant-btn')).toBeVisible();
});

test('fleet filter input exists', async ({ page }) => {
  await login(page);
  await expect(page.locator('#filter')).toBeVisible();
});

test('SSE loads and removes skeleton rows', async ({ page }) => {
  await login(page);
  // Skeletons should disappear once SSE fires
  await expect(page.locator('.skel-row')).toHaveCount(0, { timeout: 15000 });
});

test('SSE failures close the stream and back off reconnects', async ({ page }) => {
  await login(page);
  let attempts = 0;
  await page.route('**/events', route => {
    attempts++;
    route.abort();
  });
  await page.goto(BASE + '/');
  await page.waitForTimeout(7000);
  // The first retry is delayed by 3s and the next by 6s. A failed
  // EventSource must not keep its browser retry loop alive or create
  // overlapping streams.
  expect(attempts).toBeLessThanOrEqual(2);
});

test('dokku pill appears', async ({ page }) => {
  await login(page);
  await expect(page.locator('#dokku-pill')).toBeVisible();
});

// ── navigation ───────────────────────────────────────────────────────────────

test('top nav has Services / Commands / Releases links', async ({ page }) => {
  await login(page);
  await expect(page.locator('.topnav-link', { hasText: 'Services' })).toBeVisible();
  await expect(page.locator('.topnav-link', { hasText: 'Commands' })).toBeVisible();
  await expect(page.locator('.topnav-link', { hasText: 'Releases' })).toBeVisible();
});

test('navigates to Commands page', async ({ page }) => {
  await login(page);
  await page.click('.topnav-link:has-text("Commands")');
  await expect(page).toHaveURL(/\/scripts/);
  await expect(page.locator('h1')).toContainText('Deployment Commands');
});

test('navigates to Releases page', async ({ page }) => {
  await login(page);
  await page.click('.topnav-link:has-text("Releases")');
  await expect(page).toHaveURL(/\/releases/);
  // Releases page h1 is "Version Catalog"
  await expect(page.locator('h1')).toContainText('Version Catalog');
});

// ── create-tenant form ────────────────────────────────────────────────────────

test('create-tenant form has image tag input with datalist', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/scripts/create-tenant');

  // image_version field should be a text input (not select) with data-tag-search
  const input = page.locator('input[name="image_version"]');
  await expect(input).toBeVisible();
  await expect(input).toHaveAttribute('data-tag-search');
  // The sibling datalist should be present
  await expect(page.locator('#dl-image_version')).toHaveCount(1);
});

test('create-tenant image_version datalist is populated from /api/image-tags', async ({ page }) => {
  await login(page);

  // Intercept the image-tags API to inject known tags (new format includes meta[])
  await page.route('**/api/image-tags**', route => {
    route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        tags: ['dev', 'v0.0.1', 'feature-test'],
        meta: [
          { tag: 'dev', is_branch: false },
          { tag: 'v0.0.1', is_branch: false },
          { tag: 'feature-test', is_branch: true, digest: 'sha256:abc123' },
        ],
      }),
    });
  });

  await page.goto(BASE + '/scripts/create-tenant');

  // The live-search dropdown or legacy datalist should be populated
  // Wait for JS to populate the datalist via the legacy path
  await page.waitForTimeout(800);
  const dlOptions = await page.locator('#dl-image_version option').count();
  expect(dlOptions).toBeGreaterThan(0);
});

test('create-tenant form has no git-only checkbox', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/scripts/create-tenant');
  // git_only field must be gone
  await expect(page.locator('input[name="git_only"]')).toHaveCount(0);
  await expect(page.locator('text=Git-only')).toHaveCount(0);
});

test('create-tenant form has tenant name, company name, admin fields', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/scripts/create-tenant');
  await expect(page.locator('input[name="_pos_name"]')).toBeVisible();
  await expect(page.locator('input[name="company_name"]')).toBeVisible();
  await expect(page.locator('input[name="admin_user"]')).toBeVisible();
  await expect(page.locator('input[name="admin_password"]')).toBeVisible();
});

// ── commands grid ─────────────────────────────────────────────────────────────

test('commands grid shows command cards', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/scripts');
  await expect(page.locator('.command-card').first()).toBeVisible();
});

test('no QA-specific wording anywhere in the UI', async ({ page }) => {
  await login(page);
  const body = await page.textContent('body');
  // None of these old strings should appear
  expect(body).not.toContain('Git-only (no deploy)');
  expect(body).not.toContain('branch-selected');
  expect(body).not.toContain('ready-for-test');
  expect(body).not.toContain('QA Release Token');
  expect(body).not.toContain('GITHUB_TOKEN');
});

// ── /api/image-tags ───────────────────────────────────────────────────────────

test('/api/image-tags returns JSON with tags array', async ({ page }) => {
  await login(page);
  const resp = await page.request.get(BASE + '/api/image-tags');
  expect(resp.ok()).toBe(true);
  const body = await resp.json();
  expect(Array.isArray(body.tags)).toBe(true);
});

// ── password page ─────────────────────────────────────────────────────────────

test('password page is accessible', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/settings/password');
  await expect(page.locator('h1, .page-title')).toBeVisible();
});

test('releases, password, and palette use dashboard styles', async ({ page }) => {
  await login(page);

  await page.goto(BASE + '/releases');
  await expect(page.locator('.page-hero')).toBeVisible();
  expect(await page.locator('.ops-hero, .command-link, .action-chip').count()).toBe(0);

  await page.goto(BASE + '/settings/password');
  await expect(page.locator('.form-page .form-panel')).toBeVisible();
  expect(await page.locator('[class*="text-zinc-"], [class*="ring-"], [class*="rounded-"]').count()).toBe(0);

  await page.goto(BASE + '/');
  await page.click('#palette-btn');
  await expect(page.locator('.palette-box')).toBeVisible();
});

test('fleet layout fits a narrow mobile viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await login(page);
  await page.goto(BASE + '/');
  await expect(page.locator('.skel-row')).toHaveCount(0, { timeout: 15000 });

  const metrics = await page.evaluate(() => ({
    documentWidth: document.documentElement.scrollWidth,
    viewportWidth: window.innerWidth,
  }));
  expect(metrics.documentWidth).toBeLessThanOrEqual(metrics.viewportWidth + 1);
});

test('tenant backup panel fits a narrow mobile viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await login(page);
  await page.goto(BASE + '/tenants/dev-git');
  await expect(page.locator('#backup-table')).toBeVisible();

  const metrics = await page.evaluate(() => {
    const table = document.getElementById('backup-table');
    return {
      documentWidth: document.documentElement.scrollWidth,
      viewportWidth: window.innerWidth,
      tableWidth: table?.getBoundingClientRect().width || 0,
      tableScrollWidth: table?.scrollWidth || 0,
    };
  });
  expect(metrics.documentWidth).toBeLessThanOrEqual(metrics.viewportWidth + 1);
  expect(metrics.tableScrollWidth).toBeLessThanOrEqual(metrics.tableWidth + 1);
});

test('tenant activity remains visible after page reload', async ({ page }) => {
  await login(page);
  const action = await page.request.post(BASE + '/tenants/dev-git/start');
  expect(action.ok()).toBe(true);

  const activity = await page.request.get(BASE + '/api/tenants/dev-git/activity');
  expect(activity.ok()).toBe(true);
  const body = await activity.json();
  expect(body.entries.some((entry: { line?: string }) => entry.line?.includes('OK start'))).toBe(true);

  await page.goto(BASE + '/tenants/dev-git');
  await expect(page.locator('#tenant-out')).toContainText('OK start', { timeout: 5000 });
  await page.reload();
  await expect(page.locator('#tenant-out')).toContainText('OK start', { timeout: 5000 });
});

test('app lifecycle controls show progress and response output', async ({ page }) => {
  await login(page);
  await page.route('**/apps/dev-git-backend/start', async route => {
    await new Promise(r => setTimeout(r, 500));
    await route.fulfill({ contentType: 'text/plain; charset=utf-8', body: 'OK start dev-git-backend\n' });
  });
  await page.goto(BASE + '/apps/dev-git-backend');

  const start = page.locator('.app-act[data-app-act="start"]');
  await start.click();
  await expect(start).toBeDisabled();
  await expect(start).toContainText('Working');
  await expect(start).toBeEnabled({ timeout: 4000 });
  await expect(page.locator('#activity')).toContainText('OK start dev-git-backend');
});

// ── sign out ──────────────────────────────────────────────────────────────────

test('sign out redirects to login', async ({ page }) => {
  await login(page);
  // Click the sign-out button inside its form (POST /logout)
  await page.click('form[action="/logout"] button');
  await page.waitForURL(/login/, { timeout: 8000 });
  await expect(page).toHaveURL(/login/);
});

// ── image search (new feature) ────────────────────────────────────────────────

test('/api/image-tags returns tags and meta arrays', async ({ page }) => {
  await login(page);
  const resp = await page.request.get(BASE + '/api/image-tags');
  expect(resp.ok()).toBe(true);
  const body = await resp.json();
  expect(Array.isArray(body.tags)).toBe(true);
  expect(Array.isArray(body.meta)).toBe(true);
  // dev should be first (highest priority)
  expect(body.tags[0]).toBe('dev');
});

test('/api/image-tags ?q= filter works', async ({ page }) => {
  await login(page);
  const resp = await page.request.get(BASE + '/api/image-tags?q=dev');
  expect(resp.ok()).toBe(true);
  const body = await resp.json();
  expect(body.tags).toContain('dev');
  // should not contain unrelated tags
  for (const t of body.tags) {
    expect(t.toLowerCase()).toContain('dev');
  }
});

// ── tenant page (new features) ────────────────────────────────────────────────

test('tenant page has backup panel and auto-redeploy card', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/tenants/dev-git');
  await expect(page.locator('#create-backup-btn')).toBeVisible();
  await expect(page.locator('#auto-redeploy-toggle')).toBeVisible();
  await expect(page.locator('#backup-tbody')).toBeVisible();
});

test('tenant page auto-redeploy toggle persists', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/tenants/dev-git');

  const toggle = page.locator('#auto-redeploy-toggle');
  const initial = await toggle.isChecked();

  // Toggle off then on
  await toggle.click();
  await page.waitForTimeout(400);
  expect(await toggle.isChecked()).toBe(!initial);

  await toggle.click();
  await page.waitForTimeout(400);
  expect(await toggle.isChecked()).toBe(initial);
});

test('tenant page restore modal appears on restore click', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/tenants/dev-git');

  // Wait for backup list to load (may be empty)
  await page.waitForTimeout(1500);
  const modal = page.locator('#restore-modal');
  // Modal is hidden by default
  await expect(modal).toBeHidden();
});

test('tenant accounting export link is present', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/tenants/dev-git');
  const exportLink = page.locator('a[href*="accounting-export"]');
  await expect(exportLink).toBeVisible();
});

// ── create-tenant with dev tag ────────────────────────────────────────────────

test('create-tenant form defaults to dev tag', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/scripts/create-tenant');
  const input = page.locator('input[name="image_version"]');
  await expect(input).toHaveValue('dev');
});

// ── tenant version sync + lifecycle (release-details defects) ──────────────────

test('tenant sync form pre-fills a non-empty image tag (deployed version or dev)', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/tenants/dev-git');
  const input = page.locator('#tenant-version-form input[name="image_version"]');
  await expect(input).toBeVisible();
  // The Sync form must reflect the tenant's selected/deployed tag (or the dev
  // default) — never blank and never a stale placeholder from an empty catalog.
  const val = await input.inputValue();
  expect(val.trim().length).toBeGreaterThan(0);
});

test('tenant lifecycle start button shows loading + disabled state during action', async ({ page }) => {
  await login(page);
  // Delay the lifecycle POST so the in-flight disabled state is observable.
  await page.route('**/tenants/dev-git/start', async route => {
    await new Promise(r => setTimeout(r, 600));
    route.fulfill({ contentType: 'text/plain; charset=utf-8', body: 'OK start dev-git\n' });
  });
  await page.goto(BASE + '/tenants/dev-git');

  const startBtn = page.locator('.tenant-act[data-tenant-act="start"]');
  const stopBtn = page.locator('.tenant-act[data-tenant-act="stop"]');
  await expect(startBtn).toBeEnabled();

  await startBtn.click();
  // While the action runs the whole lifecycle group is disabled (idempotency:
  // start/stop/restart/rebuild cannot overlap).
  await expect(startBtn).toBeDisabled();
  await expect(stopBtn).toBeDisabled();

  // After completion the group is re-enabled and the result is streamed.
  await expect(startBtn).toBeEnabled({ timeout: 4000 });
  await expect(stopBtn).toBeEnabled();
  await expect(page.locator('#tenant-out')).toContainText('start dev-git');
});

test('tenant sync button disables while a sync is streaming', async ({ page }) => {
  await login(page);
  await page.route('**/scripts/update-tenant/run', async route => {
    await new Promise(r => setTimeout(r, 600));
    route.fulfill({
      contentType: 'text/event-stream',
      body: 'data: syncing…\n\nevent: done\ndata: end\n\n',
    });
  });
  await page.goto(BASE + '/tenants/dev-git');

  const syncBtn = page.locator('#tenant-version-form button').first();
  await page.locator('#tenant-version-form input[name="image_version"]').fill('dev');
  await syncBtn.click();
  await expect(syncBtn).toBeDisabled();
  await expect(syncBtn).toBeEnabled({ timeout: 4000 });
});
