// app.js — SSE tenant table, command palette, toast, image tag autocomplete
(() => {
  'use strict';

  // ── Toast ─────────────────────────────────────────────────
  const toastBox = document.getElementById('toast');
  const toastStatus = document.getElementById('toast-status');
  function toast(msg, kind = 'ok') {
    if (!toastBox) { alert(msg); return; }
    const el = document.createElement('div');
    el.className = 'toast ' + kind;
    el.setAttribute('aria-hidden', 'true');
    el.textContent = msg;
    if (toastStatus) toastStatus.textContent = msg;
    toastBox.appendChild(el);
    setTimeout(() => {
      el.style.opacity = '0'; el.style.transition = 'opacity .3s';
      setTimeout(() => el.remove(), 310);
    }, 2600);
  }

  // ── Command palette ───────────────────────────────────────
  const palette  = document.getElementById('palette');
  const palInput = document.getElementById('palette-input');
  const palList  = document.getElementById('palette-list');
  let palTenants = [];
  let palIdx     = 0;

  function openPalette() {
    if (!palette) return;
    palette.classList.remove('hidden');
    palette.setAttribute('aria-hidden', 'false');
    palInput.value = '';
    renderPalette('');
    palInput.focus();
  }
  function closePalette() {
    if (!palette) return;
    palette.classList.add('hidden');
    palette.setAttribute('aria-hidden', 'true');
  }

  function renderPalette(q) {
    if (!palList) return;
    const items = [];
    if (q.startsWith('>')) {
      const rest = q.slice(1).trim().toLowerCase();
      [['Services', '/'], ['Commands', '/scripts'], ['Releases', '/releases']].forEach(([label, href]) => {
        if (!rest || label.toLowerCase().includes(rest)) items.push({ label, href });
      });
    } else {
      const ql = q.toLowerCase();
      palTenants.forEach(t => {
        if (!ql || t.name.toLowerCase().includes(ql))
          items.push({ label: t.name + ' · ' + t.state, href: '/tenants/' + t.name });
      });
    }
    palIdx = 0;
    palList.innerHTML = items.slice(0, 50).map((it, i) =>
      `<li data-href="${it.href}" class="${i === 0 ? 'active' : ''}">${it.label}</li>`
    ).join('') || '<li style="color:var(--text-dim);padding:10px 12px">No matches</li>';
    palList.querySelectorAll('li[data-href]').forEach((li, i) => {
      li.addEventListener('mouseenter', () => { palIdx = i; highlightPalette(); });
      li.addEventListener('click', () => location.href = li.dataset.href);
    });
  }
  function highlightPalette() {
    palList.querySelectorAll('li').forEach((li, i) =>
      li.classList.toggle('active', i === palIdx));
  }

  if (palInput) {
    palInput.addEventListener('input', () => renderPalette(palInput.value));
    palInput.addEventListener('keydown', e => {
      const items = palList.querySelectorAll('li[data-href]');
      if (e.key === 'ArrowDown') { palIdx = Math.min(palIdx + 1, items.length - 1); highlightPalette(); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { palIdx = Math.max(palIdx - 1, 0); highlightPalette(); e.preventDefault(); }
      else if (e.key === 'Enter') { const it = items[palIdx]; if (it) location.href = it.dataset.href; }
      else if (e.key === 'Escape') closePalette();
    });
  }
  palette?.addEventListener('click', e => { if (e.target === palette) closePalette(); });
  document.getElementById('palette-btn')?.addEventListener('click', openPalette);
  document.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); openPalette(); }
    if (e.key === 'Escape') closePalette();
  });

  // ── Group flat apps[] into tenants ────────────────────────
  // SSE snapshot sends individual apps; we derive one row per tenant.
  function appDomains(app) {
    const domains = Array.isArray(app?.domains) ? app.domains : String(app?.domains || '').split(',');
    return domains.map(d => String(d).trim()).filter(Boolean);
  }

  function lifecycleOf(app) {
    return app.lifecycle_state || app.state || 'unknown';
  }

  function appProbe(app) {
    const nested = app.probe || {};
    const code = nested.http_code || app.probe_http_code || app.http || '000';
    const lifecycle = lifecycleOf(app);
    let status = nested.status || app.probe_status || '';
    if (status === 'http_error') status = 'http-error';
    const error = nested.error || app.probe_error || '';
    const unavailable = nested.unavailable_reason || app.probe_unavailable_reason || '';

    if (!status) {
      if (/^[23]\d\d$/.test(code)) status = 'healthy';
      else if (/^[45]\d\d$/.test(code)) status = 'http-error';
      else if (error) status = 'failed';
      else if (['not-deployed', 'stopped', 'exited', 'dead', 'paused', 'restarting'].includes(lifecycle))
        status = 'unavailable';
      else status = 'unknown';
    }
    return {
      status,
      code,
      checkedAt: nested.checked_at || app.probe_checked_at || '',
      error,
      unavailable
    };
  }

  function appsToTenants(apps, openStates = {}) {
    const map = new Map();
    for (const app of apps) {
      const tenant = typeof app.tenant === 'string' ? app.tenant.trim() : '';
      const appName = typeof app.name === 'string' ? app.name : '';
      const name = tenant || appName.replace(/-(backend|frontend)$/, '');
      if (!map.has(name)) {
        map.set(name, { name, apps: [], state: 'unknown', health: 'unknown', version: '', domain: '', publicURL: '' });
      }
      map.get(name).apps.push(app);
    }
    const tenants = [];
    map.forEach(t => {
      const states = t.apps.map(lifecycleOf);
      // Derive aggregate state
      if (states.every(s => s === 'running'))       t.state = 'running';
      else if (states.some(s => s === 'running'))   t.state = 'mixed';
      else if (states.every(s => s === 'stopped' || s === 'exited' || s === 'dead')) t.state = 'stopped';
      else if (states.some(s => s === 'restarting')) t.state = 'restarting';
      else if (states.every(s => s === 'not-deployed' || s === 'missing' || !s)) t.state = 'not-deployed';
      else t.state = states[0] || 'unknown';

      // Keep probe health independent from the lifecycle state.
      const backend = t.apps.find(a => a.role === 'backend') || t.apps[0];
      const frontend = t.apps.find(a => a.role === 'frontend');
      const probe = appProbe(backend || {});
      t.health = probe.status;
      t.healthCode = probe.code;
      t.healthAt = probe.checkedAt;
      t.healthError = probe.error;
      t.healthUnavailable = probe.unavailable;
      t.stateError = backend?.lifecycle_error || '';

      // Keep both component identities visible when they differ. The API
      // still exposes the original flat app fields for older consumers.
      const backendVersion = backend?.version || '';
      const frontendVersion = frontend?.version || '';
      t.version = backendVersion && frontendVersion && backendVersion !== frontendVersion
        ? backendVersion + ' / ' + frontendVersion
        : (backendVersion || frontendVersion);
      t.provenance = [backend, frontend].filter(Boolean).map(a =>
        [a.channel || a.version, a.image_ref || a.image, a.resolved_digest, a.source_commit].filter(Boolean).join(' · ')
      ).join(' | ');
      t.failed = t.apps.find(a => a.last_failure)?.last_failure || '';

      // Domain from frontend
      const feDomains = appDomains(frontend);
      const beDomains = appDomains(backend);
      t.domain = feDomains[0] || beDomains[0] || '';

      t.publicURL = frontend?.public_url || backend?.public_url || '';
      const open = openStates[t.name] || {};
      const discoveredURL = typeof open.url === 'string' ? open.url : '';
      t.openURL = t.publicURL && (t.state === 'running' || t.state === 'mixed')
        ? t.publicURL
        : discoveredURL;
      t.openUnavailable = typeof open.unavailable === 'string' ? open.unavailable : '';

      tenants.push(t);
    });
    tenants.sort((a, b) => a.name.localeCompare(b.name));
    return tenants;
  }

  // ── Status indicator class ────────────────────────────────
  function stateIndicator(state) {
    if (state === 'running')  return 'si-running';
    if (state === 'stopped' || state === 'exited' || state === 'dead') return 'si-stopped';
    if (state === 'not-deployed' || state === 'missing') return '';
    return 'si-degraded';
  }
  function healthBadgeClass(h) {
    if (h === 'healthy')    return 'badge-success';
    if (h === 'http-error' || h === 'unhealthy' || h === 'failed') return 'badge-danger';
    if (h === 'unavailable') return 'badge-neutral';
    return 'badge-warn';
  }
  function healthLabel(t) {
    if (t.health === 'healthy') return 'Healthy';
    if (t.health === 'http-error' && t.healthCode && t.healthCode !== '000') return 'HTTP ' + t.healthCode;
    if (t.health === 'failed') return 'Probe failed';
    if (t.health === 'unavailable') return 'Unavailable';
    if (t.health === 'unhealthy') return 'Unhealthy';
    return 'Unknown';
  }
  function healthDetail(t) {
    const parts = [];
    if (t.healthError) parts.push(t.healthError);
    else if (t.healthUnavailable) parts.push(t.healthUnavailable);
    else if (t.health === 'http-error' && t.healthCode) parts.push('Endpoint returned HTTP ' + t.healthCode);
    else if (t.health === 'healthy' && t.healthCode) parts.push('HTTP ' + t.healthCode);
    else if (t.health === 'unknown') parts.push('No probe result is available');
    if (t.healthCode && ['failed', 'unavailable', 'unknown'].includes(t.health)) parts.push('HTTP ' + t.healthCode);
    parts.push(t.healthAt ? 'Checked ' + formatTimestamp(t.healthAt) : 'Not checked');
    return parts.join(' · ');
  }
  function stateBadgeClass(s) {
    if (s === 'running')    return 'badge-success';
    if (s === 'stopped' || s === 'exited' || s === 'dead') return 'badge-danger';
    if (s === 'not-deployed' || s === 'missing') return 'badge-neutral';
    return 'badge-warn';
  }

  // ── Tenant table ──────────────────────────────────────────
  const tbody    = document.getElementById('tenant-tbody');
  const tpl      = document.getElementById('row-tpl');
  const filterEl = document.getElementById('filter');
  const sTotalEl = document.getElementById('s-total');
  const sRunEl   = document.getElementById('s-running');
  const sDegEl   = document.getElementById('s-degraded');
  const sStopEl  = document.getElementById('s-stopped');
  const pulseEl  = document.getElementById('pulse');
  const snapshotMetaEl = document.getElementById('snapshot-meta');
  let filterVal  = '';
  let allTenants = [];
  let currentOpenStates = {};
  let fleetStream = null;
  let fleetRetryTimer = null;
  let fleetRetryDelay = 3000;
  let fleetStableTimer = null;
  let fleetStreamClosed = false;

  function renderTable(tenants) {
    if (!tbody || !tpl) return;
    tbody.querySelectorAll('.skel-row').forEach(r => r.remove());

    const fq = filterVal.toLowerCase();
    const visible = fq ? tenants.filter(t => t.name.toLowerCase().includes(fq)) : tenants;

    const existing = {};
    tbody.querySelectorAll('.tenant-row').forEach(r => { existing[r.dataset.name] = r; });

    const fragment = document.createDocumentFragment();
    visible.forEach(tenant => {
      let row = existing[tenant.name];
      if (!row) {
        row = tpl.content.cloneNode(true).querySelector('.tenant-row');
        row.dataset.name = tenant.name;
        attachRowHandlers(row);
      }
      updateRow(row, tenant);
      fragment.appendChild(row);
      delete existing[tenant.name];
    });
    Object.values(existing).forEach(r => r.remove());
    tbody.appendChild(fragment);

    tbody.querySelector('.empty-row')?.remove();
    if (visible.length === 0) {
      const tr = document.createElement('tr');
      tr.className = 'empty-row';
      tr.innerHTML = `<td colspan="7" style="padding:32px;text-align:center;color:var(--text-dim)">No tenants${fq ? ' matching "' + fq + '"' : ''}.</td>`;
      tbody.appendChild(tr);
    }
  }

  function updateRow(row, t) {
    const ind = row.querySelector('.js-indicator');
    if (ind) ind.className = 'status-indicator ' + stateIndicator(t.state);

    const nameEl = row.querySelector('.js-name');
    if (nameEl) nameEl.textContent = t.name;
    const linkEl = row.querySelector('.js-tenant-link');
    if (linkEl) linkEl.href = '/tenants/' + t.name;
    const domainEl = row.querySelector('.js-domain');
    if (domainEl) domainEl.textContent = t.domain || '';

    const healthB = row.querySelector('.js-health-badge');
    if (healthB) {
      healthB.textContent = healthLabel(t);
      healthB.className = 'badge ' + healthBadgeClass(t.health);
      healthB.title = healthDetail(t);
    }
    const healthDetailEl = row.querySelector('.js-health-detail');
    if (healthDetailEl) healthDetailEl.textContent = healthDetail(t);

    const stateB = row.querySelector('.js-state-badge');
    if (stateB) {
      stateB.textContent = t.state || 'Unknown';
      stateB.className = 'badge ' + stateBadgeClass(t.state);
      stateB.title = 'Lifecycle state: ' + (t.state || 'unknown') + (t.stateError ? ' — ' + t.stateError : '');
    }
    const stateDetailEl = row.querySelector('.js-state-detail');
    if (stateDetailEl) stateDetailEl.textContent = t.stateError || 'Lifecycle';

    const verEl = row.querySelector('.js-version');
    if (verEl) {
      verEl.textContent = t.version || '—';
      verEl.title = t.provenance || '';
    }
    const provenanceEl = row.querySelector('.js-provenance');
    if (provenanceEl) provenanceEl.textContent = t.provenance || '';

    const appsEl = row.querySelector('.js-apps');
    if (appsEl) appsEl.textContent = t.apps.map(a => a.role || a.name).join(', ');

    const openBtn = row.querySelector('.js-open');
    const unavailableEl = row.querySelector('.js-open-unavailable');
    if (openBtn && unavailableEl) {
      if (t.openURL) {
        openBtn.href = t.openURL;
        openBtn.textContent = '↗ Open';
        openBtn.style.display = '';
        unavailableEl.style.display = 'none';
      } else {
        openBtn.removeAttribute('href');
        openBtn.style.display = 'none';
        if (t.apps.length) {
          unavailableEl.textContent = '↗ Unavailable: ' + (t.openUnavailable || 'No public URL configured');
          unavailableEl.title = unavailableEl.textContent;
          unavailableEl.style.display = '';
        } else {
          unavailableEl.textContent = '';
          unavailableEl.removeAttribute('title');
          unavailableEl.style.display = 'none';
        }
      }
    }
  }

  function setActionFeedback(row, kind, message) {
    const feedback = row.querySelector('.js-action-feedback');
    if (!feedback) return;
    feedback.className = 'action-feedback js-action-feedback' + (kind ? ' ' + kind : '');
    feedback.textContent = message;
  }

  function setRowActionWorking(row, btn, act, name) {
    const buttons = row.querySelectorAll('.btn-action[data-act]');
    row.dataset.actionPending = act;
    row.classList.add('action-pending');
    row.setAttribute('aria-busy', 'true');
    buttons.forEach(actionBtn => {
      actionBtn.disabled = true;
      actionBtn.setAttribute('aria-disabled', 'true');
    });
    btn.classList.add('is-working');
    btn.innerHTML = '<span class="action-spinner" aria-hidden="true"></span><span>Working…</span>';
    btn.setAttribute('aria-busy', 'true');
    btn.setAttribute('aria-label', act + ' ' + name + ' in progress');
    setActionFeedback(row, 'working', act + ' in progress…');
  }

  function restoreRowActions(row) {
    row.querySelectorAll('.btn-action[data-act]').forEach(actionBtn => {
      actionBtn.disabled = actionBtn.dataset.idleDisabled === 'true';
      actionBtn.removeAttribute('aria-disabled');
      actionBtn.removeAttribute('aria-busy');
      actionBtn.removeAttribute('aria-label');
      actionBtn.classList.remove('is-working');
      actionBtn.textContent = actionBtn.dataset.idleLabel || actionBtn.textContent;
    });
    row.classList.remove('action-pending');
    row.removeAttribute('aria-busy');
    delete row.dataset.actionPending;
  }

  function actionDetail(detail) {
    return String(detail || '').trim().replace(/\s+/g, ' ').slice(0, 160);
  }

  function attachRowHandlers(row) {
    const buttons = row.querySelectorAll('.btn-action[data-act]');
    buttons.forEach(btn => {
      btn.dataset.idleLabel = btn.textContent;
      btn.dataset.idleDisabled = String(btn.disabled);
      btn.addEventListener('click', async e => {
        e.stopPropagation();
        const act = btn.dataset.act;
        const name = row.dataset.name;
        if (row.dataset.actionPending) {
          toast(name + ' already has ' + row.dataset.actionPending + ' in progress.', 'err');
          return;
        }
        if ((act === 'stop' || act === 'restart') && !confirm(act + ' ' + name + '?')) return;
        setRowActionWorking(row, btn, act, name);
        try {
          const res = await fetch('/tenants/' + name + '/' + act, { method: 'POST' });
          if (res.ok) {
            toast(act + ' ' + name + ': ok', 'ok');
            setActionFeedback(row, 'success', '✓ ' + act + ' complete');
          } else {
            const detail = await res.text();
            const message = detail.trim() || ('HTTP ' + res.status);
            toast(act + ' ' + name + ': ' + message, 'err');
            setActionFeedback(row, 'failure', '✖ ' + act + ' failed: ' + (actionDetail(detail) || message));
          }
        } catch (err) {
          toast(act + ' failed: ' + err.message, 'err');
          setActionFeedback(row, 'failure', '✖ ' + act + ' failed: ' + (actionDetail(err.message) || 'request error'));
        } finally {
          restoreRowActions(row);
        }
      });
    });
  }

  function updateSummary(tenants) {
    const total   = tenants.length;
    const running = tenants.filter(t => t.state === 'running').length;
    const stopped = tenants.filter(t => t.state === 'stopped' || t.state === 'exited' || t.state === 'dead').length;
    const deg     = total - running - stopped;
    if (sTotalEl) sTotalEl.textContent = total + ' tenant' + (total === 1 ? '' : 's');
    if (sRunEl)  { sRunEl.textContent  = running + ' running'; sRunEl.style.display  = running ? '' : 'none'; }
    if (sDegEl)  { sDegEl.textContent  = deg + ' degraded';   sDegEl.style.display  = deg > 0  ? '' : 'none'; }
    if (sStopEl) { sStopEl.textContent = stopped + ' stopped'; sStopEl.style.display = stopped > 0 ? '' : 'none'; }
  }

  // ── App log stream ───────────────────────────────────────
  // EventSource reconnects are managed here so a failed stream cannot leave
  // the browser's implicit retry loop running alongside our own timer.
  function initLogStream() {
    const pre = document.getElementById('logs');
    if (!pre) return;

    const status = document.getElementById('log-stream-status');
    const retryButton = document.getElementById('log-stream-retry');
    const url = pre.dataset.streamUrl;
    if (!url) return;
    const renderer = typeof window.LogStream?.create === 'function'
      ? window.LogStream.create(pre)
      : null;

    const maxRetries = 5;
    const initialBackoff = 1000;
    const maxBackoff = 10000;
    let stream = null;
    let retryTimer = null;
    let retryCount = 0;
    let closed = false;

    const statusClasses = {
      connecting: 'badge-info',
      connected: 'badge-success',
      reconnecting: 'badge-warn',
      disconnected: 'badge-danger',
    };

    function setStatus(kind, text) {
      if (status) {
        status.textContent = text;
        status.className = 'badge ' + (statusClasses[kind] || statusClasses.connecting);
      }
      if (retryButton) retryButton.hidden = kind === 'connected' || kind === 'connecting';
    }

    function closeStream() {
      const current = stream;
      stream = null;
      if (!current) return;
      current.onopen = null;
      current.onmessage = null;
      current.onerror = null;
      current.close();
    }

    function scheduleReconnect() {
      if (closed || retryTimer !== null) return;

      retryCount += 1;
      if (retryCount > maxRetries) {
        setStatus('disconnected', 'Disconnected');
        return;
      }

      const delay = Math.min(initialBackoff * (2 ** (retryCount - 1)), maxBackoff);
      const seconds = Math.max(1, Math.ceil(delay / 1000));
      setStatus('reconnecting', 'Reconnecting in ' + seconds + 's…');
      retryTimer = setTimeout(() => {
        retryTimer = null;
        connect();
      }, delay);
    }

    function connect() {
      if (closed || stream !== null) return;
      setStatus('connecting', 'Connecting…');

      let next;
      try {
        next = new EventSource(url);
      } catch (_) {
        scheduleReconnect();
        return;
      }
      stream = next;

      next.onopen = () => {
        if (stream !== next || closed) return;
        retryCount = 0;
        setStatus('connected', 'Connected');
      };
      next.onmessage = ev => {
        if (stream !== next || closed) return;
        const stuck = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 4;
        const line = window.stripTerminalControls(ev.data);
        if (renderer) renderer.append(line);
        else pre.textContent += line + '\n';
        if (stuck) pre.scrollTop = pre.scrollHeight;
      };
      next.onerror = () => {
        if (stream !== next || closed) return;
        closeStream();
        scheduleReconnect();
      };
    }

    function retryNow() {
      if (closed) return;
      if (retryTimer !== null) {
        clearTimeout(retryTimer);
        retryTimer = null;
      }
      retryCount = 0;
      closeStream();
      connect();
    }

    retryButton?.addEventListener('click', retryNow);

    const shutdown = () => {
      if (closed) return;
      closed = true;
      if (retryTimer !== null) {
        clearTimeout(retryTimer);
        retryTimer = null;
      }
      closeStream();
    };
    window.addEventListener('beforeunload', shutdown, { once: true });
    window.addEventListener('pagehide', shutdown, { once: true });

    connect();
  }

  initLogStream();

  filterEl?.addEventListener('input', () => {
    filterVal = filterEl.value.trim();
    renderTable(allTenants);
  });

  // ── SSE stream ────────────────────────────────────────────
  function formatTimestamp(value) {
    if (!value) return '';
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleString();
  }

  function updateSnapshotMeta(data) {
    if (!snapshotMetaEl) return;
    if (data.refreshing) {
      snapshotMetaEl.textContent = 'Refreshing health snapshot…';
      return;
    }
    const parts = [];
    if (data.error) parts.push('Snapshot unavailable: ' + data.error);
    else if (data.updated_at) parts.push('Last checked ' + formatTimestamp(data.updated_at));
    if (data.dokku_error) parts.push('Dokku: ' + data.dokku_error);
    snapshotMetaEl.textContent = parts.join(' · ') || 'Health snapshot unavailable';
  }

  function bootstrapFleet() {
    const el = document.getElementById('fleet-bootstrap');
    if (!el) return;
    try {
      const data = JSON.parse(el.textContent || '{}');
      if (data.open && typeof data.open === 'object' && !Array.isArray(data.open)) {
        currentOpenStates = data.open;
      }
      allTenants = appsToTenants(data.apps || [], currentOpenStates);
      palTenants = allTenants;
      renderTable(allTenants);
      updateSummary(allTenants);
      updateSnapshotMeta(data);
    } catch (_) {}
  }

  function connectSSE() {
    if (fleetStream || fleetStreamClosed) return;
    const es = new EventSource('/events');
    fleetStream = es;
    const table = tbody?.closest('table');
    const streamStatus = document.getElementById('tenant-stream-status');
    if (table) table.setAttribute('aria-busy', 'true');
    if (streamStatus) streamStatus.textContent = 'Connecting to live tenant updates.';
    es.onopen = () => {
      if (fleetStream !== es || fleetStreamClosed) return;
      clearTimeout(fleetStableTimer);
      fleetStableTimer = setTimeout(() => { fleetRetryDelay = 3000; }, 30000);
      if (streamStatus) streamStatus.textContent = 'Live tenant updates connected.';
    };
    es.addEventListener('snapshot', ev => {
      if (fleetStream !== es || fleetStreamClosed) return;
      try {
        if (table) table.setAttribute('aria-busy', 'true');
        const data = JSON.parse(ev.data);
        // Keep bootstrap navigation metadata if an older/misconfigured
        // snapshot omits the open-state map.
        if (data.open && typeof data.open === 'object' && !Array.isArray(data.open)) {
          currentOpenStates = data.open;
        }
        allTenants = appsToTenants(data.apps || [], currentOpenStates);
        palTenants = allTenants;
        renderTable(allTenants);
        updateSummary(allTenants);
        updateSnapshotMeta(data);

        // Dokku health pill
        const pill = document.getElementById('dokku-pill');
        if (pill) {
          const st = pill.querySelector('.dokku-status');
          const dokkuStatus = data.dokku_status || (data.healthy ? 'up' : 'down');
          if (st) st.textContent = dokkuStatus;
          pill.style.color = dokkuStatus === 'up'
            ? 'var(--green)'
            : dokkuStatus === 'down' ? 'var(--red)' : 'var(--amber)';
          pill.title = data.dokku_error || ('Dokku status: ' + dokkuStatus);
        }

        if (pulseEl) {
          pulseEl.classList.add('active');
          clearTimeout(pulseEl._t);
          pulseEl._t = setTimeout(() => pulseEl.classList.remove('active'), 1200);
        }
        if (streamStatus) streamStatus.textContent = 'Live tenant updates connected.';
      } catch (_) {
        if (streamStatus) streamStatus.textContent = 'Unable to read tenant updates.';
      } finally {
        if (table) table.setAttribute('aria-busy', 'false');
      }
    });
    es.onerror = () => {
      if (fleetStream !== es || fleetStreamClosed) return;
      es.close();
      fleetStream = null;
      if (table) table.setAttribute('aria-busy', 'true');
      if (streamStatus) streamStatus.textContent = 'Live tenant updates disconnected; reconnecting.';
      if (fleetRetryTimer === null) {
        const delay = fleetRetryDelay;
        fleetRetryDelay = Math.min(fleetRetryDelay * 2, 60000);
        fleetRetryTimer = setTimeout(() => {
          fleetRetryTimer = null;
          connectSSE();
        }, delay);
      }
    };
  }

  if (document.getElementById('tenant-tbody')) {
    bootstrapFleet();
    connectSSE();
    const closeFleetStream = () => {
      fleetStreamClosed = true;
      if (fleetRetryTimer !== null) {
        clearTimeout(fleetRetryTimer);
        fleetRetryTimer = null;
      }
      clearTimeout(fleetStableTimer);
      if (fleetStream) {
        fleetStream.close();
        fleetStream = null;
      }
    };
    window.addEventListener('beforeunload', closeFleetStream, { once: true });
    window.addEventListener('pagehide', closeFleetStream, { once: true });
  }

  // ── Image tag live-search dropdown ───────────────────────
  // API: GET /api/image-tags?q=<query>
  //   → { tags: string[], default_tag: string, coverage_available: bool,
  //        meta: [{tag, is_branch, digest, last_pushed, in_both,
  //                backend_only, frontend_only}] }
  //
  // Any <input data-tag-search> gets a live-search dropdown with:
  //   - Substring filtering as you type (debounced 180ms)
  //   - A compatible default selected from the metadata response
  //   - Client-side feedback before an incompatible tag can be submitted
  //   - For branch-name tags: "points to commit: <short-sha>" subtitle
  //   - Opens on focus with full list if field is empty
  //   - Visible, announced feedback when tags are unavailable or unmatched
  //
  // The legacy <datalist id="image-tag-list"> is also kept populated for
  // backward-compat with any page that still uses it.

  function fetchTagData(q) {
    const url = '/api/image-tags' + (q ? '?q=' + encodeURIComponent(q) : '');
    return fetch(url).then(async r => {
      if (!r.ok) return { error: true };
      try {
        const data = await r.json();
        return data && typeof data === 'object' && !Array.isArray(data) ? { data } : { error: true };
      } catch (_) {
        return { error: true };
      }
    }).catch(() => ({ error: true }));
  }

  function imageScope(input) {
    const scope = input.dataset.imageScope || 'both';
    if (scope !== 'role') return scope;
    const type = input.form?.elements?.type?.value;
    if (type === 'frontend') return 'frontend';
    if (type === 'backend') return 'backend';
    const frontend = input.form?.elements?.frontend;
    if (frontend?.type === 'checkbox') return frontend.checked ? 'both' : 'backend';
    return 'both';
  }

  function tagSupportsScope(meta, scope) {
    // Older/mock tag endpoints may return only tag details. Treat missing
    // coverage fields as unknown rather than disabling an otherwise selectable
    // suggestion; the server remains the final compatibility gate.
    const hasCoverage = Object.prototype.hasOwnProperty.call(meta, 'in_both') ||
      Object.prototype.hasOwnProperty.call(meta, 'backend_only') ||
      Object.prototype.hasOwnProperty.call(meta, 'frontend_only');
    if (!hasCoverage) return true;
    if (scope === 'backend') return meta.in_both === true || meta.backend_only === true;
    if (scope === 'frontend') return meta.in_both === true || meta.frontend_only === true;
    return meta.in_both === true;
  }

  function scopeLabel(scope) {
    if (scope === 'backend') return 'backend';
    if (scope === 'frontend') return 'frontend';
    return 'both backend and frontend';
  }

  function compatibilityElement(input) {
    return input.closest('.field-row')?.querySelector('[data-image-compatibility]') ||
      input.parentElement?.querySelector('[data-image-compatibility]');
  }

  function renderInputCompatibility(input, meta, coverageAvailable) {
    const tag = input.value.trim();
    const hint = compatibilityElement(input);
    if (!tag) {
      input.setCustomValidity('');
      if (hint) hint.hidden = true;
      return;
    }
    if (!coverageAvailable) {
      const message = 'Image tag compatibility could not be verified. Refresh the page or try again before running.';
      input.setCustomValidity(message);
      if (hint) {
        hint.textContent = '⚠ ' + message;
        hint.hidden = false;
      }
      return;
    }
    if (!meta) {
      input.setCustomValidity('');
      if (hint) hint.hidden = true;
      return;
    }
    const scope = imageScope(input);
    const selected = meta.find(m => m.tag === tag);
    if (selected && tagSupportsScope(selected, scope)) {
      input.setCustomValidity('');
      if (hint) hint.hidden = true;
      return;
    }

    const message = selected
      ? `Image tag "${tag}" is not available for ${scopeLabel(scope)} images. Choose a tag marked "both repos" or published for the selected role.`
      : `Image tag "${tag}" was not found for the ${scopeLabel(scope)} image. Choose a published tag from the list.`;
    input.setCustomValidity(message);
    if (hint) {
      hint.textContent = '⚠ ' + message;
      hint.hidden = false;
    }
  }

  function updateTagDatalist(input, data) {
    const dl = document.getElementById('dl-' + input.name) ||
      document.getElementById('dl-image_version') ||
      document.getElementById('image-tag-list');
    if (!dl) return;
    dl.innerHTML = '';
    (data?.tags || []).forEach(t => {
      const o = document.createElement('option');
      o.value = t;
      dl.appendChild(o);
    });
  }

  function applyCompatibleDefault(input, data) {
    if (!data?.meta?.length || input.dataset.userChanged === '1') return;
    const current = input.value.trim();
    if (current !== '' && current !== input.defaultValue) return;
    const scope = imageScope(input);
    const preferred = data.default_tag || '';
    const preferredMeta = data.meta.find(m => m.tag === preferred && tagSupportsScope(m, scope));
    const compatible = preferredMeta || data.meta.find(m => tagSupportsScope(m, scope));
    if (compatible && input.value.trim() !== compatible.tag) {
      input.value = compatible.tag;
    }
  }

  function consumeTagData(input, data, showDropdown) {
    if (!data) return;
    input._tagMeta = data.meta || [];
    input._tagDefaultTag = data.default_tag || '';
    applyCompatibleDefault(input, data);
    updateTagDatalist(input, data);
    const coverageAvailable = data.coverage_available !== false &&
      Array.isArray(data.meta) &&
      (input._tagMeta.length > 0 || input.value.trim() !== '');
    renderInputCompatibility(input, input._tagMeta, coverageAvailable);
    if (showDropdown) buildTagDropdown(input, input._tagMeta);
  }

  function removeTagDropdown(inputId) {
    const el = document.getElementById('tag-dd-' + inputId);
    if (el) el.remove();
    const input = document.getElementById(inputId);
    if (input) {
      input.setAttribute('aria-expanded', 'false');
      input.removeAttribute('aria-activedescendant');
    }
  }

  function tagEntries(data) {
    const tags = Array.isArray(data?.tags)
      ? data.tags.filter(t => typeof t === 'string' && t)
      : [];
    const meta = Array.isArray(data?.meta)
      ? data.meta.filter(m => m && typeof m.tag === 'string' && m.tag)
      : [];
    if (!tags.length) return meta;
    const byTag = new Map(meta.map(m => [m.tag, m]));
    return tags.map(tag => byTag.get(tag) || { tag });
  }

  function tagResultMessage(query) {
    return query
      ? 'No image tags match "' + query + '".'
      : 'No image tags are available.';
  }

  function highlightTag(input, dd, idx) {
    const items = dd.querySelectorAll('.tag-dropdown-item');
    items.forEach((el, i) => {
      const selected = i === idx;
      el.classList.toggle('active', selected);
      el.setAttribute('aria-selected', String(selected));
    });
    const active = items[idx];
    if (active) input.setAttribute('aria-activedescendant', active.id);
    else input.removeAttribute('aria-activedescendant');
  }

  function selectTag(input, item) {
    const label = item.querySelector('.tag-dropdown-label');
    if (!label) return;
    input.value = label.textContent;
    input.dispatchEvent(new Event('change', { bubbles: true }));
    removeTagDropdown(input.id);
    const wrap = input.parentElement;
    if (wrap) wrap.style.position = '';
  }

  function buildTagDropdown(input, meta, message = '', query = '', messageKind = '') {
    removeTagDropdown(input.id);

    const ul = document.createElement('ul');
    ul.id = 'tag-dd-' + input.id;
    ul.className = 'tag-dropdown';
    ul.dataset.query = query;
    ul.dataset.state = messageKind || (meta.length ? 'results' : 'empty');
    ul.setAttribute('role', 'listbox');
    ul.setAttribute('aria-label', 'Image tag suggestions');

    if (message) {
      const li = document.createElement('li');
      li.className = 'tag-dropdown-message' + (messageKind ? ' tag-dropdown-' + messageKind : '');
      li.setAttribute('role', 'status');
      li.setAttribute('aria-live', 'polite');
      li.textContent = message;
      ul.appendChild(li);
    } else {
      meta.slice(0, 40).forEach((m, index) => {
        const li = document.createElement('li');
        li.id = input.id + '-option-' + index;
        const available = tagSupportsScope(m, imageScope(input));
        li.className = 'tag-dropdown-item' + (available ? '' : ' tag-partial');
        li.setAttribute('role', 'option');
        li.setAttribute('aria-selected', 'false');
        li.setAttribute('aria-disabled', available ? 'false' : 'true');

        const labelEl = document.createElement('span');
        labelEl.className = 'tag-dropdown-label';
        labelEl.textContent = m.tag;
        li.appendChild(labelEl);

        // Show commit SHA for branch tags
        if (m.is_branch && typeof m.digest === 'string' && m.digest) {
          const sub = document.createElement('span');
          sub.className = 'tag-dropdown-sub';
          const short = m.digest.replace('sha256:', '').slice(0, 12);
          sub.textContent = 'commit: ' + short;
          li.appendChild(sub);
        }

        // Show coverage for the selected flow. A role-specific action may use a
        // tag that is intentionally absent from the other repository.
        if (!available && imageScope(input) === 'both') {
          const warn = document.createElement('span');
          warn.className = 'tag-dropdown-warn';
          warn.textContent = '⚠ not available for both backend + frontend';
          li.appendChild(warn);
        } else if (m.backend_only && imageScope(input) !== 'frontend') {
          const warn = document.createElement('span');
          warn.className = 'tag-dropdown-warn';
          warn.textContent = imageScope(input) === 'backend' ? '✓ backend image' : '⚠ backend only — frontend image missing';
          li.appendChild(warn);
        } else if (m.frontend_only && imageScope(input) !== 'backend') {
          const warn = document.createElement('span');
          warn.className = 'tag-dropdown-warn';
          warn.textContent = imageScope(input) === 'frontend' ? '✓ frontend image' : '⚠ frontend only — backend image missing';
          li.appendChild(warn);
        } else if (m.in_both) {
          const ok = document.createElement('span');
          ok.className = 'tag-dropdown-ok';
          ok.textContent = imageScope(input) === 'both' ? '✓ both repos' : '✓ ' + imageScope(input) + ' image';
          li.appendChild(ok);
        }

        li.addEventListener('mouseenter', () => {
          const items = ul.querySelectorAll('.tag-dropdown-item');
          highlightTag(input, ul, Array.prototype.indexOf.call(items, li));
        });
        li.addEventListener('mousedown', e => {
          e.preventDefault();
          if (li.getAttribute('aria-disabled') === 'true') return;
          input.dataset.userChanged = '1';
          selectTag(input, li);
          renderInputCompatibility(input, input._tagMeta, true);
        });

        ul.appendChild(li);
      });
    }

    const wrap = input.parentElement;
    if (wrap) {
      wrap.style.position = 'relative';
      wrap.appendChild(ul);
    }
    input.setAttribute('aria-controls', ul.id);
    input.setAttribute('aria-expanded', 'true');
  }

  function attachTagSearch(input) {
    if (!input.id) input.id = 'tag-input-' + Math.random().toString(36).slice(2, 8);
    input.setAttribute('autocomplete', 'off');
    input.setAttribute('aria-label', input.getAttribute('aria-label') || 'Image tag');
    input.setAttribute('aria-autocomplete', 'list');
    input.setAttribute('aria-haspopup', 'listbox');
    input.setAttribute('aria-controls', 'tag-dd-' + input.id);
    input.setAttribute('aria-expanded', 'false');
    let debounce = null;
    let requestID = 0;

    function applyTagResult(q, id, result) {
      if (id !== requestID || input.value.trim() !== q) return;
      if (result.error) {
        input._tagMeta = [];
        input._tagDefaultTag = '';
        updateTagDatalist(input, { tags: [] });
        renderInputCompatibility(input, [], false);
        buildTagDropdown(input, [], 'Unable to load image tags. Try again.', q, 'error');
        return;
      }
      const data = result.data || {};
      const entries = tagEntries(data);
      input._tagMeta = data.meta || [];
      input._tagDefaultTag = data.default_tag || '';
      applyCompatibleDefault(input, data);
      updateTagDatalist(input, data);
      const coverageAvailable = data.coverage_available !== false &&
        Array.isArray(data.meta) &&
        (input._tagMeta.length > 0 || input.value.trim() !== '');
      renderInputCompatibility(input, input._tagMeta, coverageAvailable);
      buildTagDropdown(input, entries, entries.length ? '' : tagResultMessage(q), q, entries.length ? '' : 'empty');
    }

    function requestTags(q) {
      const id = ++requestID;
      fetchTagData(q).then(result => applyTagResult(q, id, result));
    }

    input.addEventListener('input', () => {
      input.dataset.userChanged = '1';
      renderInputCompatibility(input, input._tagMeta, true);
      clearTimeout(debounce);
      const q = input.value.trim();
      const id = ++requestID;
      debounce = setTimeout(() => {
        fetchTagData(q).then(result => applyTagResult(q, id, result));
      }, 180);
    });

    input.addEventListener('focus', () => {
      const q = input.value.trim();
      const dd = document.getElementById('tag-dd-' + input.id);
      if (!dd || dd.dataset.query !== q) requestTags(q);
    });

    const refreshScope = () => {
      applyCompatibleDefault(input, {
        meta: input._tagMeta || [],
        default_tag: input._tagDefaultTag || '',
      });
      renderInputCompatibility(input, input._tagMeta, true);
    };
    input.form?.elements?.type?.addEventListener('change', refreshScope);
    input.form?.elements?.frontend?.addEventListener('change', refreshScope);

    input.addEventListener('blur', () => {
      setTimeout(() => removeTagDropdown(input.id), 200);
    });

    input.addEventListener('keydown', e => {
      const dd = document.getElementById('tag-dd-' + input.id);
      if (!dd) return;
      const items = dd.querySelectorAll('.tag-dropdown-item');
      const active = dd.querySelector('.tag-dropdown-item.active');
      let idx = -1;
      items.forEach((el, i) => { if (el === active) idx = i; });
      if (e.key === 'ArrowDown' && items.length) {
        e.preventDefault();
        highlightTag(input, dd, Math.min(idx + 1, items.length - 1));
        dd.querySelector('.tag-dropdown-item.active')?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'ArrowUp' && items.length) {
        e.preventDefault();
        highlightTag(input, dd, Math.max(idx - 1, 0));
        dd.querySelector('.tag-dropdown-item.active')?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'Enter' && active) {
        e.preventDefault();
        if (active.getAttribute('aria-disabled') === 'true') return;
        selectTag(input, active);
      } else if (e.key === 'Escape') {
        removeTagDropdown(input.id);
      }
    });

    // Resolve the initial default from repository coverage metadata. This is
    // deliberately asynchronous so pages still render when Docker Hub is down.
    fetchTagData('').then(result => {
      if (!result.error) consumeTagData(input, result.data || {}, false);
    });
  }

  // Attach to all [data-tag-search] inputs once DOM is ready
  document.querySelectorAll('[data-tag-search]').forEach(attachTagSearch);

  // Legacy datalist population for pages that don't use data-tag-search
  const legacyDatalist = document.getElementById('image-tag-list');
  if (legacyDatalist) {
    fetchTagData('').then(result => {
      if (result.error) return;
      legacyDatalist.innerHTML = '';
      (result.data?.tags || []).forEach(tag => {
        const option = document.createElement('option');
        option.value = tag;
        legacyDatalist.appendChild(option);
      });
    });
  }

  // ── Kind prefix selector ──────────────────────────────────
  // When user selects a kind (dev/qa/prod), update the create-tenant link
  // to pre-fill _pos_name with the prefix and navigate to the script form.
  const kindSelect  = document.getElementById('kind-select');
  const createBtn   = document.getElementById('create-tenant-btn');
  const tenantInput = document.getElementById('new-tenant-name');

  if (createBtn) {
    createBtn.addEventListener('click', () => {
      const kind   = kindSelect?.value || 'dev';
      const name   = tenantInput?.value.trim() || '';
      const full   = kind + '-' + (name || '');
      // Navigate to create-tenant script with tenant name pre-filled
      const url = '/scripts/create-tenant' + (name ? '?_pos_name=' + encodeURIComponent(full) : '');
      location.href = url;
    });
    tenantInput?.addEventListener('keydown', e => {
      if (e.key === 'Enter') { e.preventDefault(); createBtn.click(); }
    });
  }

  // ── HTMX toast ────────────────────────────────────────────
  document.addEventListener('htmx:afterRequest', ev => {
    if (!ev.detail.successful) toast('Action failed: ' + (ev.detail.xhr?.statusText || 'error'), 'err');
    else toast('Done.', 'ok');
  });

})();
