// Shared operation-state and browser activity persistence helpers.
(() => {
  'use strict';

  const STATES = Object.freeze(['idle', 'running', 'success', 'failure']);
  const LABELS = Object.freeze({
    idle: 'Idle',
    running: 'Running',
    success: 'Success',
    failure: 'Failure',
  });
  const DETAILS = Object.freeze({
    idle: 'Ready — run an operation to see output.',
    running: 'Working — waiting for output…',
    success: 'Completed successfully.',
    failure: 'The operation failed. Review the output below.',
  });
  const MAX_ENTRIES = 200;

  function normalizeState(state) {
    return STATES.includes(state) ? state : 'idle';
  }

  function setState(panel, state, detail) {
    const normalized = normalizeState(state);
    if (!panel) return normalized;

    panel.dataset.state = normalized;
    panel.dataset.operationState = normalized;
    panel.setAttribute('aria-busy', normalized === 'running' ? 'true' : 'false');

    const status = panel.querySelector('[data-operation-status]');
    if (status) {
      status.dataset.state = normalized;
      status.dataset.operationStatus = normalized;
      status.className = 'operation-status operation-status-' + normalized;
      status.textContent = LABELS[normalized];
    }

    const detailEl = panel.querySelector('[data-operation-detail]');
    if (detailEl) detailEl.textContent = detail || DETAILS[normalized];

    return normalized;
  }

  function recoveredState(state, hasEntries) {
    if (!hasEntries) return 'idle';
    // A page refresh cannot prove a run was still active. Treat an unfinished
    // persisted run as failed rather than claiming that it is still running.
    return normalizeState(state) === 'running' ? 'failure' : normalizeState(state);
  }

  function createStore(key) {
    const storageKey = String(key || '');

    function load() {
      if (!storageKey) return { entries: [], state: 'idle' };
      try {
        const raw = JSON.parse(localStorage.getItem(storageKey) || '{}');
        const entries = Array.isArray(raw.entries)
          ? raw.entries.filter(entry => typeof entry === 'string').slice(-MAX_ENTRIES)
          : [];
        return { entries, state: normalizeState(raw.state) };
      } catch (_) {
        return { entries: [], state: 'idle' };
      }
    }

    function save(entries, state) {
      if (!storageKey) return;
      const value = {
        version: 1,
        entries: Array.isArray(entries)
          ? entries.filter(entry => typeof entry === 'string').slice(-MAX_ENTRIES)
          : [],
        state: normalizeState(state),
      };
      try { localStorage.setItem(storageKey, JSON.stringify(value)); } catch (_) {}
    }

    function clear() {
      if (!storageKey) return;
      try { localStorage.removeItem(storageKey); } catch (_) {}
    }

    return Object.freeze({ load, save, clear });
  }

  window.DashboardOperation = Object.freeze({
    states: STATES,
    labels: LABELS,
    details: DETAILS,
    maxEntries: MAX_ENTRIES,
    normalizeState,
    recoveredState,
    setState,
    createStore,
  });
})();
