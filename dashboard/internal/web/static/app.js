// app.js — SSE tenant table, command palette, toast, image tag autocomplete
(() => {
  'use strict';

  // ── Toast ─────────────────────────────────────────────────
  const toastBox = document.getElementById('toast');
  function toast(msg, kind = 'ok') {
    if (!toastBox) { alert(msg); return; }
    const el = document.createElement('div');
    el.className = 'toast ' + kind;
    el.textContent = msg;
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
    palInput.value = '';
    renderPalette('');
    palInput.focus();
  }
  function closePalette() { palette && palette.classList.add('hidden'); }

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
  function appsToTenants(apps) {
    const map = new Map();
    for (const app of apps) {
      const name = app.tenant || app.name.replace(/-(backend|frontend)$/, '');
      if (!map.has(name)) {
        map.set(name, { name, apps: [], state: 'unknown', health: 'unknown', version: '', domain: '' });
      }
      map.get(name).apps.push(app);
    }
    const tenants = [];
    map.forEach(t => {
      const states = t.apps.map(a => a.state);
      // Derive aggregate state
      if (states.every(s => s === 'running'))       t.state = 'running';
      else if (states.some(s => s === 'running'))   t.state = 'mixed';
      else if (states.every(s => s === 'stopped' || s === 'exited' || s === 'dead')) t.state = 'stopped';
      else if (states.some(s => s === 'restarting')) t.state = 'restarting';
      else if (states.every(s => s === 'not-deployed' || s === 'missing' || !s)) t.state = 'not-deployed';
      else t.state = states[0] || 'unknown';

      // Derive health from HTTP code of backend
      const backend = t.apps.find(a => a.role === 'backend') || t.apps[0];
      const frontend = t.apps.find(a => a.role === 'frontend');
      if (t.state === 'running') {
        const code = parseInt(backend?.http || '0', 10);
        if (code >= 200 && code < 400) t.health = 'healthy';
        else if (code === 0)           t.health = 'unknown';
        else                           t.health = 'unhealthy';
      } else if (t.state === 'not-deployed') {
        t.health = 'not-deployed';
      } else {
        t.health = t.state;
      }

      // Version from backend image tag
      t.version = backend?.version || '';

      // Domain from frontend
      const feDomains = frontend?.domains ? frontend.domains.split(',').filter(Boolean) : [];
      t.domain = feDomains[0] || (backend?.domains ? backend.domains.split(',')[0] : '');

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
    if (h === 'unhealthy')  return 'badge-danger';
    if (h === 'not-deployed') return 'badge-neutral';
    return 'badge-warn';
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
  let filterVal  = '';
  let allTenants = [];

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
    if (healthB) { healthB.textContent = t.health || '—'; healthB.className = 'badge ' + healthBadgeClass(t.health); }

    const stateB = row.querySelector('.js-state-badge');
    if (stateB) { stateB.textContent = t.state || '—'; stateB.className = 'badge ' + stateBadgeClass(t.state); }

    const verEl = row.querySelector('.js-version');
    if (verEl) verEl.textContent = t.version || '—';

    const appsEl = row.querySelector('.js-apps');
    if (appsEl) appsEl.textContent = t.apps.map(a => a.role || a.name).join(', ');

    const openBtn = row.querySelector('.js-open');
    if (openBtn) {
      if (t.domain && t.state === 'running') {
        openBtn.href = 'http://' + t.domain;
        openBtn.style.display = '';
      } else {
        openBtn.style.display = 'none';
      }
    }
  }

  function attachRowHandlers(row) {
    row.querySelectorAll('.btn-action[data-act]').forEach(btn => {
      btn.addEventListener('click', async e => {
        e.stopPropagation();
        const act = btn.dataset.act;
        const name = row.dataset.name;
        if ((act === 'stop' || act === 'restart') && !confirm(act + ' ' + name + '?')) return;
        btn.disabled = true;
        try {
          const res = await fetch('/tenants/' + name + '/' + act, { method: 'POST' });
          toast(act + ' ' + name + ': ' + (res.ok ? 'ok' : await res.text()), res.ok ? 'ok' : 'err');
        } catch (err) {
          toast(act + ' failed: ' + err.message, 'err');
        } finally {
          btn.disabled = false;
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

  filterEl?.addEventListener('input', () => {
    filterVal = filterEl.value.trim();
    renderTable(allTenants);
  });

  // ── SSE stream ────────────────────────────────────────────
  let currentSSE = null;
  let reconnectTimer = null;
  let reconnectDelay = 3000;
  let stableTimer = null;

  function scheduleSSEReconnect() {
    if (reconnectTimer !== null) return;
    const delay = reconnectDelay;
    reconnectDelay = Math.min(reconnectDelay * 2, 60000);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connectSSE();
    }, delay);
  }

  function connectSSE() {
    if (reconnectTimer !== null) return;
    if (currentSSE) currentSSE.close();

    const es = new EventSource('/events');
    currentSSE = es;
    es.addEventListener('open', () => {
      clearTimeout(stableTimer);
      stableTimer = setTimeout(() => { reconnectDelay = 3000; }, 30000);
    });
    es.addEventListener('snapshot', ev => {
      try {
        const data = JSON.parse(ev.data);
        allTenants = appsToTenants(data.apps || []);
        palTenants = allTenants;
        renderTable(allTenants);
        updateSummary(allTenants);

        // Dokku health pill
        const pill = document.getElementById('dokku-pill');
        if (pill) {
          const st = pill.querySelector('.dokku-status');
          if (st) st.textContent = data.healthy ? 'up' : 'down';
          pill.style.color = data.healthy ? 'var(--green)' : 'var(--red)';
        }

        if (pulseEl) {
          pulseEl.classList.add('active');
          clearTimeout(pulseEl._t);
          pulseEl._t = setTimeout(() => pulseEl.classList.remove('active'), 1200);
        }
      } catch (_) {}
    });
    es.onerror = () => {
      if (currentSSE !== es) return;
      clearTimeout(stableTimer);
      es.close();
      currentSSE = null;
      scheduleSSEReconnect();
    };
  }

  if (document.getElementById('tenant-tbody')) {
    connectSSE();
    window.addEventListener('beforeunload', () => {
      clearTimeout(reconnectTimer);
      clearTimeout(stableTimer);
      if (currentSSE) currentSSE.close();
    });
  }

  // ── Image tag live-search dropdown ───────────────────────
  // API: GET /api/image-tags?q=<query>
  //   → { tags: string[], meta: [{tag, is_branch, digest, last_pushed}] }
  //
  // Any <input data-tag-search> gets a live-search dropdown with:
  //   - Substring filtering as you type (debounced 180ms)
  //   - For branch-name tags: "points to commit: <short-sha>" subtitle
  //   - Opens on focus with full list if field is empty
  //
  // The legacy <datalist id="image-tag-list"> is also kept populated for
  // backward-compat with any page that still uses it.

  function fetchTagData(q) {
    const url = '/api/image-tags' + (q ? '?q=' + encodeURIComponent(q) : '');
    return fetch(url).then(r => r.ok ? r.json() : null).catch(() => null);
  }

  function removeTagDropdown(inputId) {
    const el = document.getElementById('tag-dd-' + inputId);
    if (el) el.remove();
  }

  function buildTagDropdown(input, meta) {
    removeTagDropdown(input.id);
    if (!meta || meta.length === 0) return;

    const ul = document.createElement('ul');
    ul.id = 'tag-dd-' + input.id;
    ul.className = 'tag-dropdown';

    meta.slice(0, 40).forEach(m => {
      const li = document.createElement('li');
      // Visually dim tags that only exist in one repo — they will cause deploy failures
      li.className = 'tag-dropdown-item' + (m.in_both === false && (m.backend_only || m.frontend_only) ? ' tag-partial' : '');

      const labelEl = document.createElement('span');
      labelEl.className = 'tag-dropdown-label';
      labelEl.textContent = m.tag;
      li.appendChild(labelEl);

      // Show commit SHA for branch tags
      if (m.is_branch && m.digest) {
        const sub = document.createElement('span');
        sub.className = 'tag-dropdown-sub';
        const short = m.digest.replace('sha256:', '').slice(0, 12);
        sub.textContent = 'commit: ' + short;
        li.appendChild(sub);
      }

      // Show warning if tag only exists in one repo
      if (m.backend_only) {
        const warn = document.createElement('span');
        warn.className = 'tag-dropdown-warn';
        warn.textContent = '⚠ backend only — frontend image missing';
        li.appendChild(warn);
      } else if (m.frontend_only) {
        const warn = document.createElement('span');
        warn.className = 'tag-dropdown-warn';
        warn.textContent = '⚠ frontend only — backend image missing';
        li.appendChild(warn);
      } else if (m.in_both) {
        const ok = document.createElement('span');
        ok.className = 'tag-dropdown-ok';
        ok.textContent = '✓ both repos';
        li.appendChild(ok);
      }

      li.addEventListener('mousedown', e => {
        e.preventDefault();
        input.value = m.tag;
        input.dispatchEvent(new Event('change', { bubbles: true }));
        removeTagDropdown(input.id);
        const wrap = input.parentElement;
        if (wrap) wrap.style.position = '';
      });

      ul.appendChild(li);
    });

    const wrap = input.parentElement;
    if (wrap) {
      wrap.style.position = 'relative';
      wrap.appendChild(ul);
    }
  }

  function attachTagSearch(input) {
    if (!input.id) input.id = 'tag-input-' + Math.random().toString(36).slice(2, 8);
    input.setAttribute('autocomplete', 'off');
    let debounce = null;

    input.addEventListener('input', () => {
      clearTimeout(debounce);
      debounce = setTimeout(() => {
        fetchTagData(input.value.trim()).then(data => {
          if (data) {
            buildTagDropdown(input, data.meta || []);
            // Also update legacy datalist
            const dl = document.getElementById('dl-image_version') || document.getElementById('image-tag-list');
            if (dl) {
              dl.innerHTML = '';
              (data.tags || []).forEach(t => {
                const o = document.createElement('option'); o.value = t; dl.appendChild(o);
              });
            }
          }
        });
      }, 180);
    });

    input.addEventListener('focus', () => {
      const q = input.value.trim();
      if (!document.getElementById('tag-dd-' + input.id)) {
        fetchTagData(q).then(data => data && buildTagDropdown(input, data.meta || []));
      }
    });

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
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        const next = Math.min(idx + 1, items.length - 1);
        items.forEach((el, i) => el.classList.toggle('active', i === next));
        items[next]?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        const prev = Math.max(idx - 1, 0);
        items.forEach((el, i) => el.classList.toggle('active', i === prev));
        items[prev]?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'Enter' && active) {
        e.preventDefault();
        input.value = active.querySelector('.tag-dropdown-label').textContent;
        input.dispatchEvent(new Event('change', { bubbles: true }));
        removeTagDropdown(input.id);
      } else if (e.key === 'Escape') {
        removeTagDropdown(input.id);
      }
    });
  }

  // Attach to all [data-tag-search] inputs once DOM is ready
  document.querySelectorAll('[data-tag-search]').forEach(attachTagSearch);

  // Legacy datalist population for pages that don't use data-tag-search
  const legacyDatalist = document.getElementById('image-tag-list');
  if (legacyDatalist) {
    fetchTagData('').then(data => {
      if (!data?.tags?.length) return;
      data.tags.forEach(t => {
        const o = document.createElement('option'); o.value = t; legacyDatalist.appendChild(o);
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
