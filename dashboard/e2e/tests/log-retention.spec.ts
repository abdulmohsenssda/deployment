import { test, expect } from '@playwright/test';
import path from 'node:path';

const LOG_STREAM_SCRIPT = path.resolve(__dirname, '../../internal/web/static/log-stream.js');

test('bounded log renderer keeps newest safe output and links', async ({ page }) => {
  await page.setContent(`
    <pre id="logs" style="height:20px;overflow:auto;line-height:20px;margin:0"></pre>
    <pre id="bytes"></pre>
  `);
  await page.addScriptTag({ path: LOG_STREAM_SCRIPT });

  const result = await page.evaluate(() => {
    const api = (window as any).LogStream;
    const logs = api.create(document.getElementById('logs'), { maxLines: 3, maxBytes: 1024 });
    logs.append('old-1');
    logs.append('old-2');
    logs.append('\u001b[31mkeep-1 https://example.test/build/42 <img src=x onerror=alert(1)>\u001b[0m');
    const output = document.getElementById('logs');
    output.scrollTop = output.scrollHeight;
    logs.append('keep-2');
    logs.append('keep-3');

    const bytes = api.create(document.getElementById('bytes'), { maxLines: 10, maxBytes: 12 });
    bytes.append('old-line');
    bytes.append('new-line');

    return {
      lines: Array.from(output.querySelectorAll('[data-log-line]'), line => line.textContent),
      links: Array.from(output.querySelectorAll('a'), link => ({
        text: link.textContent,
        href: (link as HTMLAnchorElement).href,
      })),
      hasUnsafeElement: !!output.querySelector('img, script'),
      byteLines: Array.from(document.getElementById('bytes').querySelectorAll('[data-log-line]'), line => line.textContent),
      atBottom: output.scrollTop + output.clientHeight >= output.scrollHeight - 1,
      defaults: [api.MAX_LINES, api.MAX_BYTES],
    };
  });

  expect(result.lines).toEqual([
    '\u001b[31mkeep-1 https://example.test/build/42 <img src=x onerror=alert(1)>\u001b[0m',
    'keep-2',
    'keep-3',
  ]);
  expect(result.links).toEqual([{
    text: 'https://example.test/build/42',
    href: 'https://example.test/build/42',
  }]);
  expect(result.hasUnsafeElement).toBe(false);
  expect(result.byteLines).toEqual(['new-line']);
  expect(result.atBottom).toBe(true);
  expect(result.defaults).toEqual([2000, 1024 * 1024]);
});
