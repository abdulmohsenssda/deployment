// logs.js — terminal-control filtering for streamed output
(() => {
  'use strict';

  const ESC = 0x1b;

  function isEscFinal(code) {
    return code >= 0x30 && code <= 0x7e;
  }

  function csiEnd(value, start) {
    for (let i = start; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code >= 0x30 && code <= 0x3f) continue;
      if (code >= 0x20 && code <= 0x2f) continue;
      if (code >= 0x40 && code <= 0x7e) return i + 1;
      return -1;
    }
    return -1;
  }

  function stringEnd(value, start, osc) {
    for (let i = start; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (osc && code === 0x07) return i + 1;
      if (code === 0x9c) return i + 1;
      if (code === ESC && value.charCodeAt(i + 1) === 0x5c) return i + 2;
    }
    return -1;
  }

  function escapeEnd(value, start) {
    if (value.charCodeAt(start) !== ESC || start + 1 >= value.length) return -1;
    const next = value.charCodeAt(start + 1);
    if (next === 0x5b) return csiEnd(value, start + 2);
    if (next === 0x5d) return stringEnd(value, start + 2, true);
    if (next === 0x50 || next === 0x5e || next === 0x5f || next === 0x58)
      return stringEnd(value, start + 2, false);
    if (next === 0x5c || isEscFinal(next)) return start + 2;
    if (next >= 0x20 && next <= 0x2f) {
      let i = start + 2;
      while (i < value.length && value.charCodeAt(i) >= 0x20 && value.charCodeAt(i) <= 0x2f) i++;
      return i < value.length && isEscFinal(value.charCodeAt(i)) ? i + 1 : -1;
    }
    return -1;
  }

  function c1End(value, start) {
    const code = value.charCodeAt(start);
    if (code === 0x9b) return csiEnd(value, start + 1);
    if (code === 0x9d) return stringEnd(value, start + 1, true);
    if (code === 0x90 || code === 0x98 || code === 0x9e || code === 0x9f)
      return stringEnd(value, start + 1, false);
    if (code === 0x9c) return start + 1;
    return -1;
  }

  function stripTerminalControls(value) {
    value = String(value);
    let out = '';
    for (let i = 0; i < value.length;) {
      const code = value.charCodeAt(i);
      if (code === ESC) {
        const end = escapeEnd(value, i);
        i = end >= 0 ? end : i + 1;
      } else if (code === 0x0a || code === 0x09) {
        out += value[i++];
      } else if (code === 0x0d) {
        i++;
      } else if (code >= 0x80 && code <= 0x9f) {
        const end = c1End(value, i);
        i = end >= 0 ? end : i + 1;
      } else if (code < 0x20 || code === 0x7f) {
        i++;
      } else {
        out += value[i++];
      }
    }
    return out;
  }

  window.stripTerminalControls = stripTerminalControls;
})();
