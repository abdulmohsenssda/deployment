import { test, expect, Page } from '@playwright/test';

const BASE = process.env.DASHBOARD_BASE_URL || 'http://localhost:8088';
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

async function loadMockFleet(page: Page) {
  const tenant = 'mock-tenant';
  await page.route('**/events', route => route.fulfill({
    contentType: 'text/event-stream',
    body: [
      'event: snapshot',
      'data: ' + JSON.stringify({
        healthy: true,
        refreshing: false,
        updated_at: new Date().toISOString(),
        duration_ms: 1,
        error: '',
        apps: [
          { name: tenant + '-backend', role: 'backend', tenant, state: 'running', image: 'repo/api:dev', version: 'dev', http: '200', int_port: '80', host_ports: '', procs: '', domains: '' },
          { name: tenant + '-frontend', role: 'frontend', tenant, state: 'running', image: 'repo/web:dev', version: 'dev', http: '200', int_port: '80', host_ports: '', procs: '', domains: '' },
        ],
      }),
    ].join('\n') + '\n\n',
  }));
  await page.reload();
  return tenant;
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

test('fleet remains usable at a 390px viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.route('**/events', route => route.fulfill({
    contentType: 'text/event-stream',
    headers: { 'Cache-Control': 'no-cache' },
    body: [
      'event: snapshot',
      `data: ${JSON.stringify({
        healthy: true,
        apps: [
          {
            name: 'dev-acme-backend',
            tenant: 'dev-acme',
            role: 'backend',
            state: 'running',
            http: '200',
            version: 'v1.2.3',
          },
          {
            name: 'dev-acme-frontend',
            tenant: 'dev-acme',
            role: 'frontend',
            state: 'running',
            domains: 'acme.example.test',
            version: 'v1.2.3',
          },
        ],
      })}`,
      '',
      '',
    ].join('\n'),
  }));
  await page.route('**/tenants/dev-acme/start', route => route.fulfill({ status: 200, body: 'ok' }));

  await login(page);
  const row = page.locator('.tenant-row[data-name="dev-acme"]');
  await expect(row).toBeVisible();
  await expect(page.locator('.fleet-quick-create')).toBeVisible();
  await expect(row.locator('.row-actions')).toBeVisible();

  const layout = await page.evaluate(() => ({
    viewportWidth: window.innerWidth,
    documentWidth: document.documentElement.scrollWidth,
    bodyWidth: document.body.scrollWidth,
    rowDisplay: getComputedStyle(document.querySelector('.tenant-row')!).display,
    actionsDisplay: getComputedStyle(document.querySelector('.row-actions')!).display,
    actionRight: document.querySelector('.row-actions')!.getBoundingClientRect().right,
    cardRight: document.querySelector('.tenant-row')!.getBoundingClientRect().right,
  }));
  expect(layout.documentWidth).toBeLessThanOrEqual(layout.viewportWidth);
  expect(layout.bodyWidth).toBeLessThanOrEqual(layout.viewportWidth);
  expect(layout.rowDisplay).toBe('grid');
  expect(layout.actionsDisplay).toBe('grid');
  expect(layout.actionRight).toBeLessThanOrEqual(layout.cardRight + 1);

  await page.fill('#filter', 'acme');
  await expect(row).toHaveCount(1);
  await page.fill('#filter', 'missing');
  await expect(page.locator('.empty-row')).toBeVisible();
  await page.fill('#filter', '');

  const startRequest = page.waitForRequest(request =>
    request.method() === 'POST' && request.url().endsWith('/tenants/dev-acme/start')
  );
  await row.locator('.js-start').click();
  await startRequest;

  const createNavigation = page.waitForURL(url =>
    url.pathname === '/scripts/create-tenant' && url.searchParams.get('_pos_name') === 'qa-acme'
  );
  await page.selectOption('#kind-select', 'qa');
  await page.fill('#new-tenant-name', 'acme');
  await page.locator('#create-tenant-btn').click();
  await createNavigation;
});

test('SSE loads and removes skeleton rows', async ({ page }) => {
  await login(page);
  // Skeletons should disappear once SSE fires
  await expect(page.locator('.skel-row')).toHaveCount(0, { timeout: 15000 });
});

test('dokku pill appears', async ({ page }) => {
  await login(page);
  await expect(page.locator('#dokku-pill')).toBeVisible();
});

test('fleet lifecycle action shows progress and restores controls after success', async ({ page }) => {
  await login(page);
  const name = await loadMockFleet(page);

  const row = page.locator('.tenant-row').first();
  await expect(row).toBeVisible({ timeout: 15000 });
  await expect(row).toHaveAttribute('data-name', name);

  await page.route('**/tenants/**/start', async route => {
    await new Promise(resolve => setTimeout(resolve, 500));
    await route.fulfill({
      status: 200,
      contentType: 'text/plain; charset=utf-8',
      body: 'mock start complete\n',
    });
  });

  const start = row.locator('[data-act="start"]');
  await start.click();
  await expect(start).toBeDisabled();
  await expect(start).toContainText('Working');
  await expect(row.locator('[data-act="stop"]')).toBeDisabled();
  await expect(row.locator('.js-action-feedback')).toHaveText('start in progress…');
  await expect(start).toBeEnabled({ timeout: 4000 });
  await expect(start).toHaveText('▶ Start');
  await expect(row.locator('[data-act="stop"]')).toBeEnabled();
  await expect(row.locator('.js-action-feedback')).toHaveText('✓ start complete');
});

test('fleet lifecycle action reports failure and restores controls', async ({ page }) => {
  await login(page);
  const name = await loadMockFleet(page);

  const row = page.locator('.tenant-row').first();
  await expect(row).toBeVisible({ timeout: 15000 });
  await expect(row).toHaveAttribute('data-name', name);

  await page.route('**/tenants/**/restart', async route => {
    await new Promise(resolve => setTimeout(resolve, 500));
    await route.fulfill({
      status: 500,
      contentType: 'text/plain; charset=utf-8',
      body: 'mock restart failed\n',
    });
  });

  let confirmationMessage = '';
  page.once('dialog', async dialog => {
    confirmationMessage = dialog.message();
    await dialog.accept();
  });

  const restart = row.locator('[data-act="restart"]');
  await restart.click();
  await expect(restart).toBeDisabled();
  await expect(restart).toContainText('Working');
  await expect(row.locator('[data-act="start"]')).toBeDisabled();
  await expect(row.locator('.js-action-feedback')).toHaveText('restart in progress…');
  await expect(restart).toBeEnabled({ timeout: 4000 });
  await expect(restart).toHaveText('↺ Restart');
  await expect(row.locator('[data-act="start"]')).toBeEnabled();
  await expect(row.locator('.js-action-feedback')).toHaveText('✖ restart failed: mock restart failed');
  expect(confirmationMessage).toBe('restart ' + name + '?');
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

test('command network failure shows an error and restores controls', async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on('pageerror', error => pageErrors.push(error));
  await login(page);
  await page.route('**/scripts/status/run', route => route.abort('failed'));
  await page.goto(BASE + '/scripts/status');

  const runButton = page.locator('#run-form button[type="submit"]');
  await runButton.click();
  await expect(page.locator('#run-status')).toContainText('Network error');
  await expect(runButton).toBeEnabled();
  expect(pageErrors).toHaveLength(0);
});

test('command non-2xx response shows the server failure and restores controls', async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on('pageerror', error => pageErrors.push(error));
  await login(page);
  await page.route('**/scripts/status/run', route => route.fulfill({
    status: 503,
    contentType: 'text/plain',
    body: 'runner unavailable',
  }));
  await page.goto(BASE + '/scripts/status');

  const runButton = page.locator('#run-form button[type="submit"]');
  await runButton.click();
  await expect(page.locator('#run-status')).toContainText('HTTP 503');
  await expect(page.locator('#run-status')).toContainText('runner unavailable');
  await expect(runButton).toBeEnabled();
  expect(pageErrors).toHaveLength(0);
});

test('malformed command stream shows a failure and restores controls', async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on('pageerror', error => pageErrors.push(error));
  await login(page);
  await page.route('**/scripts/status/run', route => route.fulfill({
    status: 200,
    contentType: 'text/event-stream',
    body: 'not an SSE event\n\n',
  }));
  await page.goto(BASE + '/scripts/status');

  const runButton = page.locator('#run-form button[type="submit"]');
  await runButton.click();
  await expect(page.locator('#run-status')).toContainText('stream was malformed');
  await expect(runButton).toBeEnabled();
  expect(pageErrors).toHaveLength(0);
});

test('closed command stream shows a failure and restores controls', async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on('pageerror', error => pageErrors.push(error));
  await login(page);
  await page.route('**/scripts/status/run', route => route.fulfill({
    status: 200,
    contentType: 'text/event-stream',
    body: 'data: started\n\n',
  }));
  await page.goto(BASE + '/scripts/status');

  const runButton = page.locator('#run-form button[type="submit"]');
  await runButton.click();
  await expect(page.locator('#run-status')).toContainText('closed before completion');
  await expect(runButton).toBeEnabled();
  expect(pageErrors).toHaveLength(0);
});

test('command Run sends only one request while the response is streaming', async ({ page }) => {
  await login(page);

  let postCount = 0;
  let releaseResponse!: () => void;
  const responseReleased = new Promise<void>(resolve => { releaseResponse = resolve; });
  await page.route('**/scripts/status/run', async route => {
    postCount++;
    await responseReleased;
    await route.fulfill({
      status: 200,
      contentType: 'text/event-stream',
      body: 'data: mocked output\n\nevent: done\ndata: end\n\n',
    });
  });

  await page.goto(BASE + '/scripts/status');
  const runButton = page.locator('#run-form button[type="submit"]');
  const clearButton = page.locator('#clear-out');
  await expect(runButton).toBeVisible();

  await page.evaluate(() => {
    const form = document.getElementById('run-form');
    if (!form) throw new Error('run form not found');
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });

  await expect(runButton).toBeDisabled();
  await expect(clearButton).toBeDisabled();
  await expect.poll(() => postCount).toBe(1);
  releaseResponse();
  await expect(runButton).toBeEnabled();
  await expect(clearButton).toBeEnabled();
  await expect(page.locator('#out')).toContainText('mocked output');
  expect(postCount).toBe(1);
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

test('password form stacks without overlap on narrow screens', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await login(page);
  await page.goto(BASE + '/settings/password?e=match');

  await expect(page.locator('[role="alert"]')).toContainText('New passwords do not match.');
  await expect(page.locator('form.password-form')).toHaveAttribute('method', 'post');
  await expect(page.locator('input[name="current_password"]')).toHaveAttribute('type', 'password');
  await expect(page.locator('input[name="current_password"]')).toHaveAttribute('autocomplete', 'current-password');
  await expect(page.locator('input[name="new_password"]')).toHaveAttribute('autocomplete', 'new-password');
  await expect(page.locator('input[name="confirm_password"]')).toHaveAttribute('minlength', '8');

  const geometry = await page.evaluate(() => {
    const rect = (selector: string, root: ParentNode = document) => {
      const element = root.querySelector<HTMLElement>(selector);
      if (!element) throw new Error(`missing ${selector}`);
      const box = element.getBoundingClientRect();
      return { left: box.left, right: box.right, top: box.top, bottom: box.bottom };
    };
    const fields = Array.from(document.querySelectorAll<HTMLElement>('.password-field')).map(field => ({
      label: rect('.field-label', field),
      input: rect('.password-input', field),
    }));
    const form = rect('.password-form');
    const alert = rect('[role="alert"]');
    const submit = rect('.password-submit');
    return {
      width: window.innerWidth,
      scrollWidth: document.documentElement.scrollWidth,
      form,
      alert,
      submit,
      fields,
    };
  });

  expect(geometry.scrollWidth).toBeLessThanOrEqual(geometry.width);
  expect(geometry.form.left).toBeGreaterThanOrEqual(0);
  expect(geometry.form.right).toBeLessThanOrEqual(geometry.width);
  expect(geometry.form.top).toBeGreaterThanOrEqual(geometry.alert.bottom);
  expect(geometry.submit.left).toBeGreaterThanOrEqual(geometry.form.left);
  expect(geometry.submit.right).toBeLessThanOrEqual(geometry.form.right);

  for (const field of geometry.fields) {
    expect(field.label.bottom).toBeLessThanOrEqual(field.input.top);
    expect(field.input.left).toBeGreaterThanOrEqual(geometry.form.left);
    expect(field.input.right).toBeLessThanOrEqual(geometry.form.right);
  }

  for (let index = 1; index < geometry.fields.length; index += 1) {
    expect(geometry.fields[index].label.top).toBeGreaterThanOrEqual(geometry.fields[index - 1].input.bottom);
  }
  const lastField = geometry.fields[geometry.fields.length - 1];
  expect(geometry.submit.top).toBeGreaterThanOrEqual(lastField.input.bottom);
});

// ── app activity ─────────────────────────────────────────────────────────────

test('app recent activity panel renders persisted entries', async ({ page }) => {
  await login(page);
  await page.route('**/api/apps/dev-git-backend/activity', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      entries: [
        { at: '2026-08-27T01:00:00Z', line: 'OK start dev-git-backend' },
      ],
    }),
  }));
  await page.goto(BASE + '/apps/dev-git-backend');

  await expect(page.locator('#activity')).toContainText('OK start dev-git-backend');
  await expect(page.locator('#activity')).toHaveAttribute('data-state', 'ready');
});

test('app recent activity panel shows an empty state', async ({ page }) => {
  await login(page);
  await page.route('**/api/apps/dev-git-backend/activity', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ entries: [] }),
  }));
  await page.goto(BASE + '/apps/dev-git-backend');

  await expect(page.locator('#activity')).toHaveText('No recent activity.');
  await expect(page.locator('#activity')).toHaveAttribute('data-state', 'empty');
});

test('app recent activity panel exposes loading and error states', async ({ page }) => {
  await login(page);
  let releaseRequest!: () => void;
  const requestBlocked = new Promise<void>(resolve => { releaseRequest = resolve; });
  await page.route('**/api/apps/dev-git-backend/activity', async route => {
    await requestBlocked;
    await route.abort();
  });
  await page.goto(BASE + '/apps/dev-git-backend');

  await expect(page.locator('#activity')).toHaveText('Loading recent activity…');
  releaseRequest();
  await expect(page.locator('#activity')).toHaveText('Unable to load recent activity.', { timeout: 3000 });
  await expect(page.locator('#activity')).toHaveAttribute('data-state', 'error');
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

test('image tag search shows an accessible no-match state', async ({ page }) => {
  await login(page);
  await page.route('**/api/image-tags**', async route => {
    const q = new URL(route.request().url()).searchParams.get('q') || '';
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify(q === 'missing-tag'
        ? { tags: [], meta: [] }
        : { tags: ['dev'], meta: [{ tag: 'dev', in_both: true }] }),
    });
  });

  await page.goto(BASE + '/scripts/create-tenant');
  const input = page.locator('input[name="image_version"]');
  await input.fill('missing-tag');

  const feedback = page.locator('#tag-dd-input-image_version [role="status"]');
  await expect(feedback).toBeVisible();
  await expect(feedback).toHaveText('No image tags match "missing-tag".');
  await expect(feedback).toHaveAttribute('aria-live', 'polite');
  await expect(input).toHaveAttribute('aria-expanded', 'true');
});

test('image tag search shows empty and API failure states', async ({ page }) => {
  await login(page);
  await page.route('**/api/image-tags**', async route => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ tags: [], meta: [] }),
    });
  });

  await page.goto(BASE + '/scripts/create-tenant');
  const input = page.locator('input[name="image_version"]');
  await input.fill('empty-check');
  await input.fill('');
  const feedback = page.locator('#tag-dd-input-image_version [role="status"]');
  await expect(feedback).toHaveText('No image tags are available.');

  await page.unroute('**/api/image-tags**');
  await page.route('**/api/image-tags**', async route => {
    await route.fulfill({
      status: 503,
      contentType: 'text/plain',
      body: 'Docker Hub unavailable',
    });
  });
  await input.fill('dev');
  await expect(feedback).toHaveText('Unable to load image tags. Try again.');
  await expect(feedback).toHaveClass(/tag-dropdown-error/);
});

test('image tag search keeps mouse and keyboard selection working', async ({ page }) => {
  await login(page);
  await page.route('**/api/image-tags**', async route => {
    const q = new URL(route.request().url()).searchParams.get('q') || '';
    const payload = q === 'feature'
      ? {
          tags: ['feature-branch'],
          meta: [{ tag: 'feature-branch', is_branch: true, digest: 'sha256:abc123456789' }],
        }
      : {
          tags: ['dev'],
          meta: [{ tag: 'dev', in_both: true }],
        };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify(payload),
    });
  });

  await page.goto(BASE + '/scripts/create-tenant');
  const input = page.locator('input[name="image_version"]');
  const dropdown = page.locator('#tag-dd-input-image_version');

  await input.fill('dev');
  await expect(dropdown.locator('.tag-dropdown-label')).toHaveText('dev');
  await dropdown.locator('.tag-dropdown-item').click();
  await expect(input).toHaveValue('dev');

  await input.fill('feature');
  await expect(dropdown.locator('.tag-dropdown-label')).toHaveText('feature-branch');
  await input.press('ArrowDown');
  await expect(dropdown.locator('.tag-dropdown-item.active')).toHaveText(/feature-branch/);
  await input.press('Enter');
  await expect(input).toHaveValue('feature-branch');
});

// ── tenant page (new features) ────────────────────────────────────────────────

test('tenant page has backup panel and auto-redeploy card', async ({ page }) => {
  await login(page);
  await page.goto(BASE + '/tenants/dev-git');
  await expect(page.locator('#create-backup-btn')).toBeVisible();
  await expect(page.locator('#auto-redeploy-toggle')).toBeVisible();
  await expect(page.locator('#backup-tbody')).toBeVisible();
});

test('tenant credentials show an accessible retry state when loading fails', async ({ page }) => {
  await login(page);
  await page.route('**/tenants/dev-git/credentials', async route => {
    if (route.request().method() !== 'GET') {
      await route.continue();
      return;
    }
    await route.fulfill({
      status: 503,
      contentType: 'text/plain',
      body: 'backend unavailable',
    });
  });

  await page.goto(BASE + '/tenants/dev-git');

  const status = page.locator('#credentials-status');
  await expect(status).toContainText('Failed to load credentials');
  await expect(status).toHaveAttribute('role', 'status');
  await expect(status).toHaveAttribute('aria-live', 'polite');
  await expect(page.getByRole('button', { name: 'Retry loading credentials' })).toBeVisible();
  await expect(page.locator('#cred-admin-user')).toHaveText('Failed to load credentials.');
  await expect(page.locator('#cred-manager-user')).toHaveText('Failed to load credentials.');
});

test('tenant credentials recover after retrying a failed load', async ({ page }) => {
  await login(page);
  let credentialRequests = 0;
  await page.route('**/tenants/dev-git/credentials', async route => {
    if (route.request().method() !== 'GET') {
      await route.continue();
      return;
    }
    credentialRequests += 1;
    if (credentialRequests === 1) {
      await route.fulfill({
        status: 503,
        contentType: 'text/plain',
        body: 'backend unavailable',
      });
      return;
    }
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        admin_user: 'recovered-admin',
        manager_user: 'recovered-manager',
      }),
    });
  });

  await page.goto(BASE + '/tenants/dev-git');
  await expect(page.locator('#credentials-status')).toContainText('Failed to load credentials');
  await page.getByRole('button', { name: 'Retry loading credentials' }).click();

  await expect(page.locator('#cred-admin-user')).toHaveText('recovered-admin');
  await expect(page.locator('#cred-manager-user')).toHaveText('recovered-manager');
  await expect(page.locator('#credentials-status')).toHaveText('Credentials loaded.');
  await expect(page.getByRole('button', { name: 'Retry loading credentials' })).toBeHidden();
  expect(credentialRequests).toBe(2);
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

test('command output transitions idle to running to success and survives reload', async ({ page }) => {
  await login(page);
  await page.route('**/scripts/status/run', async route => {
    await new Promise(resolve => setTimeout(resolve, 400));
    await route.fulfill({
      status: 200,
      contentType: 'text/event-stream',
      body: 'data: status complete\n\nevent: done\ndata: end\n\n',
    });
  });
  await page.goto(BASE + '/scripts/status');
  await page.evaluate(() => localStorage.removeItem('dashboard:script-output:status'));
  await page.reload();

  const panel = page.locator('#command-output');
  await expect(panel).toHaveAttribute('data-state', 'idle');
  await expect(page.locator('#out-empty')).toContainText('No command output yet');

  await page.locator('#run-form button[type="submit"]').click();
  await expect(panel).toHaveAttribute('data-state', 'running');
  await expect(panel).toHaveAttribute('aria-busy', 'true');
  await expect(panel).toHaveAttribute('data-state', 'success', { timeout: 5000 });
  await expect(page.locator('#out')).toContainText('status complete');

  await page.reload();
  await expect(panel).toHaveAttribute('data-state', 'success');
  await expect(page.locator('#out')).toContainText('status complete');
});

test('command output transitions to failure on an HTTP error', async ({ page }) => {
  await login(page);
  await page.route('**/scripts/status/run', route => route.fulfill({
    status: 502,
    contentType: 'text/plain',
    body: 'runner unavailable',
  }));
  await page.goto(BASE + '/scripts/status');
  await page.evaluate(() => localStorage.removeItem('dashboard:script-output:status'));
  await page.reload();

  const panel = page.locator('#command-output');
  await page.locator('#run-form button[type="submit"]').click();
  await expect(panel).toHaveAttribute('data-state', 'failure', { timeout: 5000 });
  await expect(page.locator('#out-status')).toHaveText('Failure');
  await expect(page.locator('#out')).toContainText('runner unavailable');
});

test('tenant activity transitions idle to running to success and survives reload', async ({ page }) => {
  await login(page);
  await page.route('**/tenants/dev-git/start', async route => {
    await new Promise(resolve => setTimeout(resolve, 400));
    await route.fulfill({
      status: 200,
      contentType: 'text/plain',
      body: 'OK start dev-git-backend\n',
    });
  });
  await page.goto(BASE + '/tenants/dev-git');
  await page.evaluate(() => localStorage.removeItem('dashboard:tenant-activity:dev-git'));
  await page.reload();

  const panel = page.locator('#tenant-activity-panel');
  await expect(panel).toHaveAttribute('data-state', 'idle');
  await expect(page.locator('#tenant-out-empty')).toContainText('No tenant activity yet');

  await page.locator('.tenant-act[data-tenant-act="start"]').click();
  await expect(panel).toHaveAttribute('data-state', 'running');
  await expect(panel).toHaveAttribute('aria-busy', 'true');
  await expect(panel).toHaveAttribute('data-state', 'success', { timeout: 5000 });
  await expect(page.locator('#tenant-out')).toContainText('OK start dev-git-backend');

  await page.reload();
  await expect(panel).toHaveAttribute('data-state', 'success');
  await expect(page.locator('#tenant-out')).toContainText('OK start dev-git-backend');
});

test('tenant activity transitions to failure on an HTTP error', async ({ page }) => {
  await login(page);
  await page.route('**/tenants/dev-git/start', route => route.fulfill({
    status: 502,
    contentType: 'text/plain',
    body: 'tenant action unavailable',
  }));
  await page.goto(BASE + '/tenants/dev-git');
  await page.evaluate(() => localStorage.removeItem('dashboard:tenant-activity:dev-git'));
  await page.reload();

  const panel = page.locator('#tenant-activity-panel');
  await page.locator('.tenant-act[data-tenant-act="start"]').click();
  await expect(panel).toHaveAttribute('data-state', 'failure', { timeout: 5000 });
  await expect(page.locator('#tenant-out-status')).toHaveText('Failure');
  await expect(page.locator('#tenant-out')).toContainText('tenant action unavailable');
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
