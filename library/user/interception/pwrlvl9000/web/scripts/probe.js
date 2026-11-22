/* probe.js — Probe Sniffer + Client Tracker */
'use strict';

function buildProbe() {
    const el = document.getElementById('tab-probe');
    el.innerHTML = `
<div class="section-title">// PROBE SNIFFER + CLIENT TRACKER</div>

<div class="status-row">
  <div class="dot" id="probe-dot"></div>
  <span id="probe-status-txt">IDLE</span>
</div>

<!-- Probe Scanner -->
<div class="card">
  <div class="section-title">PROBE SNIFFER</div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="probe-iface" class="form-input"></select>
    </div>
    <div class="form-group">
      <label class="form-label">DURATION (s)</label>
      <input id="probe-duration" class="form-input" type="number" value="60" min="10" max="300">
    </div>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-green" onclick="probeStart()">&#9655; SNIFF</button>
    <button class="btn btn-muted btn-sm" onclick="probeStop()">&#9632; STOP</button>
  </div>
</div>

<!-- Probe Results -->
<div class="card">
  <div class="section-title">PROBING DEVICES <span id="probe-count" class="badge badge-found" style="display:none"></span></div>
  <div id="probe-table" class="table-wrap">
    <div class="empty">No probe data — run sniffer first</div>
  </div>
</div>

<!-- Client Tracker -->
<div class="card">
  <div class="section-title">CLIENT TRACKER <span id="client-count" class="badge badge-found" style="display:none"></span></div>
  <div class="btn-group mt-8" style="margin-bottom:8px">
    <button class="btn btn-cyan btn-sm" onclick="refreshClients()">&#8635; REFRESH</button>
  </div>
  <div id="client-table" class="table-wrap">
    <div class="empty">No client data yet</div>
  </div>
</div>`;

    _populateProbeIface((getStatus() || {}).interfaces);
    refreshClients();
}

function _populateProbeIface(ifaces) {
    const list = (ifaces && ifaces.length) ? ifaces : ['wlan0mon', 'wlan1mon', 'wlan2mon', 'wlan0open', 'wlan0mgmt'];
    const sel = document.getElementById('probe-iface');
    if (!sel) return;
    const cur = sel.value;
    sel.innerHTML = list.map(i => `<option value="${esc(i)}">${esc(i)}</option>`).join('');
    if (list.includes(cur)) sel.value = cur;
}

function renderProbes(clients) {
    const el    = document.getElementById('probe-table');
    const badge = document.getElementById('probe-count');
    if (!el) return;
    const probing = clients.filter(c => c.ssids && c.ssids.length > 0);
    if (!probing.length) {
        el.innerHTML = '<div class="empty">No probe requests captured yet</div>';
        if (badge) badge.style.display = 'none';
        return;
    }
    if (badge) { badge.textContent = probing.length; badge.style.display = 'inline-block'; }
    el.innerHTML = `
<table class="data-table">
<thead><tr><th>MAC</th><th>PWR</th><th>PROBED SSIDs</th></tr></thead>
<tbody>
  ${probing.map(c => `
  <tr>
    <td style="font-size:12px">${esc(c.mac)}</td>
    <td>${esc(c.power)}</td>
    <td style="color:var(--cyan);font-size:12px">${c.ssids.map(esc).join(', ')}</td>
  </tr>`).join('')}
</tbody>
</table>`;
}

function renderClients(clients) {
    const el    = document.getElementById('client-table');
    const badge = document.getElementById('client-count');
    if (!el) return;
    if (!clients.length) {
        el.innerHTML = '<div class="empty">No clients visible</div>';
        if (badge) badge.style.display = 'none';
        return;
    }
    if (badge) { badge.textContent = clients.length + ' clients'; badge.style.display = 'inline-block'; }
    el.innerHTML = `
<table class="data-table">
<thead><tr><th>MAC</th><th>PWR</th><th>BSSID</th><th>LAST SEEN</th></tr></thead>
<tbody>
  ${clients.map(c => `
  <tr>
    <td style="font-size:12px">${esc(c.mac)}</td>
    <td>${esc(c.power)}</td>
    <td style="font-size:11px">${c.bssid ? esc(c.bssid) : '<span style="color:var(--muted)">—</span>'}</td>
    <td style="font-size:11px;color:var(--muted)">${esc(c.last_seen || '')}</td>
  </tr>`).join('')}
</tbody>
</table>`;
}

async function probeStart() {
    const iface    = document.getElementById('probe-iface').value;
    const duration = parseInt(document.getElementById('probe-duration').value) || 60;
    const res = await api('/api/probe/start', {
        method: 'POST', body: JSON.stringify({ iface, duration }),
    });
    if (res && res.ok) toast(`Probe sniffing on ${iface}...`, 'success');
    else               toast((res && res.msg) || 'Failed', 'error');
}

async function probeStop() {
    await api('/api/probe/stop', { method: 'POST', body: '{}' });
    toast('Probe scan stopped', 'info');
}

async function refreshClients() {
    const res = await api('/api/clients');
    if (res && res.clients) renderClients(res.clients);
}

function updateProbeUI(s) {
    if (!s) return;
    if (s.interfaces) _populateProbeIface(s.interfaces);
    const dot = document.getElementById('probe-dot');
    const txt = document.getElementById('probe-status-txt');
    if (dot) dot.className = s.probe_running ? 'dot active' : 'dot';
    if (txt) {
        txt.textContent  = s.probe_running ? 'SNIFFING...' : 'IDLE';
        txt.style.color  = s.probe_running ? '#ffcc00' : '';
    }
}

let _probePollTimer = null;

function _startProbePoll() {
    _stopProbePoll();
    _probePollTimer = setInterval(async () => {
        const res = await api('/api/probe/results');
        if (res && res.clients) renderProbes(res.clients);
    }, 4000);
}

function _stopProbePoll() {
    if (_probePollTimer) { clearInterval(_probePollTimer); _probePollTimer = null; }
}

registerTab('probe', {
    onActivate:   () => { buildProbe(); _startProbePoll(); },
    onDeactivate: _stopProbePoll,
    onStatus:     updateProbeUI,
});

window.probeStart     = probeStart;
window.probeStop      = probeStop;
window.refreshClients = refreshClients;
