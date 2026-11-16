/* wps.js — WPS Scanner + Pixie Dust Attack */
'use strict';

function buildWPS() {
    const el = document.getElementById('tab-wps');
    el.innerHTML = `
<div class="section-title">// WPS ATTACK</div>

<div class="status-row">
  <div class="dot" id="wps-dot"></div>
  <span id="wps-status-txt">IDLE</span>
</div>

<!-- WPS Scanner -->
<div class="card">
  <div class="section-title">WPS SCANNER (WASH)</div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="wps-iface" class="form-input"></select>
    </div>
    <div class="form-group">
      <label class="form-label">DURATION (s)</label>
      <input id="wps-duration" class="form-input" type="number" value="30" min="10" max="120">
    </div>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-green" onclick="wpsStartScan()">&#9655; SCAN</button>
    <button class="btn btn-muted btn-sm" onclick="wpsStopScan()">&#9632; STOP</button>
  </div>
</div>

<!-- WPS Networks -->
<div class="card">
  <div class="section-title">WPS NETWORKS <span id="wps-count" class="badge badge-found" style="display:none"></span></div>
  <div id="wps-table" class="table-wrap">
    <div class="empty">No WPS networks found — run scanner first</div>
  </div>
</div>

<!-- Attack Panel (shown when target selected) -->
<div class="card" id="wps-attack-card" style="display:none">
  <div class="section-title">PIXIE DUST ATTACK</div>
  <div class="status-row" style="margin-bottom:8px">
    <div class="dot" id="wps-atk-dot"></div>
    <span id="wps-atk-txt">IDLE</span>
  </div>
  <div class="form-group">
    <label class="form-label">TARGET BSSID</label>
    <input id="wps-target-bssid" class="form-input" type="text" readonly>
  </div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">CHANNEL</label>
      <input id="wps-target-ch" class="form-input" type="number" readonly>
    </div>
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="wps-atk-iface" class="form-input"></select>
    </div>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-red" onclick="wpsStartAttack()">&#9889; PIXIE DUST</button>
    <button class="btn btn-muted btn-sm" onclick="wpsStopAttack()">&#9632; STOP</button>
    <button class="btn btn-muted btn-sm" onclick="wpsCloseAttack()">&#215; CLOSE</button>
  </div>
</div>`;

    _populateWPSIfaces((getStatus() || {}).interfaces);
    refreshWPS();
}

function _populateWPSIfaces(ifaces) {
    const list = (ifaces && ifaces.length) ? ifaces : ['wlan0mon', 'wlan1mon', 'wlan2mon', 'wlan0open', 'wlan0mgmt'];
    ['wps-iface', 'wps-atk-iface'].forEach(id => {
        const sel = document.getElementById(id);
        if (!sel) return;
        const cur = sel.value;
        sel.innerHTML = list.map(i => `<option value="${esc(i)}">${esc(i)}</option>`).join('');
        if (list.includes(cur)) sel.value = cur;
    });
}

function renderWPS(aps) {
    const el    = document.getElementById('wps-table');
    const badge = document.getElementById('wps-count');
    if (!el) return;
    if (!aps || !aps.length) {
        el.innerHTML = '<div class="empty">No WPS networks found yet</div>';
        if (badge) badge.style.display = 'none';
        return;
    }
    if (badge) { badge.textContent = aps.length; badge.style.display = 'inline-block'; }
    el.innerHTML = `
<table class="data-table">
<thead><tr><th>BSSID</th><th>CH</th><th>PWR</th><th>LCK</th><th>ESSID</th><th></th></tr></thead>
<tbody>
  ${aps.map(a => `
  <tr>
    <td style="font-size:11px">${esc(a.bssid)}</td>
    <td>${esc(a.channel)}</td>
    <td>${esc(a.rssi)}</td>
    <td>${a.locked === 'Yes'
      ? '<span style="color:var(--red)">LCK</span>'
      : '<span style="color:var(--green)">OPEN</span>'}</td>
    <td style="color:var(--cyan);font-size:12px">${esc(a.essid || '—')}</td>
    <td>
      <button class="btn btn-sm btn-red"
              onclick="wpsOpenAttack(${JSON.stringify(a.bssid)},${JSON.stringify(String(a.channel))})">&#9889;</button>
    </td>
  </tr>`).join('')}
</tbody>
</table>`;
}

function wpsOpenAttack(bssid, channel) {
    const card = document.getElementById('wps-attack-card');
    const tb   = document.getElementById('wps-target-bssid');
    const tc   = document.getElementById('wps-target-ch');
    if (card) card.style.display = 'block';
    if (tb)   tb.value = bssid;
    if (tc)   tc.value = channel;
    if (card) card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function wpsCloseAttack() {
    const card = document.getElementById('wps-attack-card');
    if (card) card.style.display = 'none';
}

async function wpsStartScan() {
    const iface    = document.getElementById('wps-iface').value;
    const duration = parseInt(document.getElementById('wps-duration').value) || 30;
    const res = await api('/api/wps/scan', {
        method: 'POST', body: JSON.stringify({ iface, duration }),
    });
    if (res && res.ok) toast(`WPS scan on ${iface}...`, 'success');
    else               toast((res && res.msg) || 'Failed', 'error');
}

async function wpsStopScan() {
    await api('/api/wps/stop_scan', { method: 'POST', body: '{}' });
    toast('WPS scan stopped', 'info');
}

async function wpsStartAttack() {
    const bssid   = (document.getElementById('wps-target-bssid').value || '').trim();
    const channel = parseInt(document.getElementById('wps-target-ch').value) || 6;
    const iface   = document.getElementById('wps-atk-iface').value;
    if (!bssid) { toast('No target selected', 'error'); return; }
    const res = await api('/api/wps/attack', {
        method: 'POST', body: JSON.stringify({ bssid, channel, iface }),
    });
    if (res && res.ok) toast(`Pixie dust \u2192 ${bssid}`, 'warn');
    else               toast((res && res.msg) || 'Failed', 'error');
}

async function wpsStopAttack() {
    await api('/api/wps/stop_attack', { method: 'POST', body: '{}' });
    toast('WPS attack stopped', 'info');
}

async function refreshWPS() {
    const res = await api('/api/wps/results');
    if (res && res.aps) renderWPS(res.aps);
}

function updateWPSUI(s) {
    if (!s) return;
    if (s.interfaces) _populateWPSIfaces(s.interfaces);

    const dot  = document.getElementById('wps-dot');
    const txt  = document.getElementById('wps-status-txt');
    const aDot = document.getElementById('wps-atk-dot');
    const aTxt = document.getElementById('wps-atk-txt');

    const busy = s.wps_scanning || s.wps_attacking;
    if (dot) dot.className = busy ? 'dot attacking' : 'dot';
    if (txt) {
        txt.textContent = s.wps_attacking
            ? `ATTACKING: ${s.wps_target || ''}`
            : s.wps_scanning ? 'SCANNING...' : 'IDLE';
        txt.style.color = busy ? '#ff2020' : '';
    }
    if (aDot) aDot.className = s.wps_attacking ? 'dot attacking' : 'dot';
    if (aTxt) {
        aTxt.textContent = s.wps_attacking ? `ATTACKING: ${s.wps_target || ''}` : 'IDLE';
        aTxt.style.color = s.wps_attacking ? '#ff2020' : '';
    }
}

let _wpsPollTimer = null;

function _startWPSPoll() {
    _stopWPSPoll();
    _wpsPollTimer = setInterval(refreshWPS, 5000);
}

function _stopWPSPoll() {
    if (_wpsPollTimer) { clearInterval(_wpsPollTimer); _wpsPollTimer = null; }
}

registerTab('wps', {
    onActivate:   () => { buildWPS(); _startWPSPoll(); },
    onDeactivate: _stopWPSPoll,
    onStatus:     updateWPSUI,
});

window.wpsStartScan   = wpsStartScan;
window.wpsStopScan    = wpsStopScan;
window.wpsStartAttack = wpsStartAttack;
window.wpsStopAttack  = wpsStopAttack;
window.wpsOpenAttack  = wpsOpenAttack;
window.wpsCloseAttack = wpsCloseAttack;
window.refreshWPS     = refreshWPS;
