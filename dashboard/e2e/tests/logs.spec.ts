import { test, expect } from '@playwright/test';

test('terminal output filters ANSI controls and preserves ordinary multiline text', async ({ page }) => {
  await page.goto('/login');

  const rendered = await page.evaluate(() => {
    const raw = '\u001b[31mred\u001b[0m\nplain \u001b[31';
    const pre = document.createElement('pre');
    pre.textContent = (window as any).stripTerminalControls(raw);
    document.body.appendChild(pre);
    return { text: pre.textContent, html: pre.innerHTML };
  });

  expect(rendered.text).toBe('red\nplain [31');
  expect(rendered.html).toBe('red\nplain [31');
});
