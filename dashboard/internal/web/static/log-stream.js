// Bounded log rendering for long-running dashboard streams.
(() => {
  'use strict';

  // Keep these aligned with LOG_BUFFER_LINES and the 1 MiB scanner limit on
  // the server. The browser keeps the newest entries within both limits.
  const DEFAULT_MAX_LINES = 2000;
  const DEFAULT_MAX_BYTES = 1024 * 1024;
  const NEWLINE_BYTES = 1;
  const URL_RE = /https?:\/\/[^\s<>"\u001b]+/g;

  const encoder = typeof TextEncoder === 'function' ? new TextEncoder() : null;

  function byteLength(value) {
    if (encoder) return encoder.encode(value).length;
    let bytes = 0;
    for (const char of value) {
      const codePoint = char.codePointAt(0);
      bytes += codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
    }
    return bytes;
  }

  function positiveInteger(value, fallback) {
    const n = Number(value);
    const integer = Math.floor(n);
    return Number.isFinite(integer) && integer > 0 ? integer : fallback;
  }

  function truncateToBytes(value, maxBytes) {
    if (byteLength(value) <= maxBytes) return value;
    let out = '';
    let used = 0;
    for (const char of value) {
      const size = byteLength(char);
      if (used + size > maxBytes) break;
      out += char;
      used += size;
    }
    return out;
  }

  function appendLinkedText(parent, value) {
    let cursor = 0;
    value.replace(URL_RE, (url, offset) => {
      if (offset > cursor) parent.appendChild(document.createTextNode(value.slice(cursor, offset)));
      const link = document.createElement('a');
      link.className = 'log-link';
      link.href = url;
      link.target = '_blank';
      link.rel = 'noopener';
      link.textContent = url;
      parent.appendChild(link);
      cursor = offset + url.length;
      return url;
    });
    if (cursor < value.length) parent.appendChild(document.createTextNode(value.slice(cursor)));
  }

  class LogStream {
    constructor(container, options = {}) {
      this.container = container;
      this.maxLines = positiveInteger(options.maxLines, DEFAULT_MAX_LINES);
      this.maxBytes = positiveInteger(options.maxBytes, DEFAULT_MAX_BYTES);
      this.entries = [];
      this.bytes = 0;
    }

    append(line) {
      const raw = String(line ?? '');
      const value = typeof window.stripTerminalControls === 'function'
        ? window.stripTerminalControls(raw)
        : raw;
      const maxContentBytes = Math.max(0, this.maxBytes - NEWLINE_BYTES);
      const bounded = truncateToBytes(value, maxContentBytes);
      const entryBytes = byteLength(bounded) + NEWLINE_BYTES;
      const stuck = this.container.scrollTop + this.container.clientHeight >= this.container.scrollHeight - 4;

      const lineEl = document.createElement('span');
      lineEl.className = 'log-line';
      lineEl.dataset.logLine = '';
      appendLinkedText(lineEl, bounded);
      const newline = document.createTextNode('\n');
      this.container.append(lineEl, newline);

      this.entries.push({ lineEl, newline, bytes: entryBytes });
      this.bytes += entryBytes;
      while (this.entries.length > this.maxLines || this.bytes > this.maxBytes) {
        const oldest = this.entries.shift();
        oldest.lineEl.remove();
        oldest.newline.remove();
        this.bytes -= oldest.bytes;
      }

      if (stuck) this.container.scrollTop = this.container.scrollHeight;
    }

    clear() {
      this.entries = [];
      this.bytes = 0;
      this.container.replaceChildren();
    }
  }

  window.LogStream = Object.freeze({
    MAX_LINES: DEFAULT_MAX_LINES,
    MAX_BYTES: DEFAULT_MAX_BYTES,
    create(container, options) {
      return new LogStream(container, options);
    },
  });
})();
