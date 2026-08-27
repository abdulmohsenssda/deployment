import { test, expect } from '@playwright/test';
import path from 'node:path';

const appScript = path.resolve(__dirname, '../../internal/web/static/app.js');

test('app log stream reconnects after a mocked disconnect', async ({ page }) => {
  await page.setContent(`
    <div id="log-stream-status" class="badge badge-info" role="status" aria-live="polite">Connecting…</div>
    <button id="log-stream-retry" type="button" hidden>Retry now</button>
    <pre id="logs" data-stream-url="/apps/mock-backend/logs"></pre>
  `);
  await page.evaluate(() => {
    class MockEventSource {
      static instances: MockEventSource[] = [];
      url: string;
      closed = false;
      onopen: ((event: Event) => void) | null = null;
      onmessage: ((event: MessageEvent) => void) | null = null;
      onerror: ((event: Event) => void) | null = null;

      constructor(url: string) {
        this.url = url;
        MockEventSource.instances.push(this);
      }

      close() {
        this.closed = true;
      }

      emit(kind: 'open' | 'message' | 'error', data = '') {
        const event = { data } as MessageEvent;
        if (kind === 'open') this.onopen?.(event);
        if (kind === 'message') this.onmessage?.(event);
        if (kind === 'error') this.onerror?.(event);
      }
    }

    (window as unknown as { __mockLogStreams: MockEventSource[] }).__mockLogStreams =
      MockEventSource.instances;
    Object.defineProperty(window, 'EventSource', {
      configurable: true,
      writable: true,
      value: MockEventSource,
    });
  });
  await page.addScriptTag({ path: appScript });

  const streams = () => page.evaluate(() => (
    (window as unknown as { __mockLogStreams: Array<{ closed: boolean }> }).__mockLogStreams
  ));

  await expect.poll(async () => (await streams()).length).toBe(1);
  await page.evaluate(() => {
    const source = (window as unknown as {
      __mockLogStreams: Array<{ emit: (kind: 'error') => void }>;
    }).__mockLogStreams[0];
    source.emit('error');
  });

  await expect(page.locator('#log-stream-status')).toContainText('Reconnecting');
  await expect(page.locator('#log-stream-retry')).toBeVisible();
  await expect.poll(async () => (await streams()).length, { timeout: 3000 }).toBe(2);
  expect((await streams())[0].closed).toBe(true);

  await page.evaluate(() => {
    const source = (window as unknown as {
      __mockLogStreams: Array<{ emit: (kind: 'open') => void }>;
    }).__mockLogStreams[1];
    source.emit('open');
  });
  await expect(page.locator('#log-stream-status')).toHaveText('Connected');
});
