/* rogueap.js — Evil Twin / Rogue AP + Beacon Flood */
'use strict';

function buildRogueAP() {
    const el = document.getElementById('tab-rogueap');
    el.innerHTML = `
<div class="section-title">// ROGUE AP + BEACON FLOOD</div>

<!-- Rogue AP status -->
<div class="status-row">
  <div class="dot" id="ra-dot"></div>
  <span id="ra-status-txt">IDLE</span>
</div>

<!-- Evil Twin -->
<div class="card">
  <div class="section-title">EVIL TWIN (HOSTAPD)</div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">SSID</label>
      <input id="ra-ssid" class="form-input" placeholder="FreeWiFi" type="text">
    </div>
    <div class="form-group">
      <label class="form-label">CHANNEL</label>
      <input id="ra-channel" class="form-input" type="number" value="6" min="1" max="13">
    </div>
  </div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="ra-iface" class="form-input"></select>
    </div>
    <div class="form-group">
      <label class="form-label">WPA2 PASSWORD (blank=OPEN)</label>
      <input id="ra-password" class="form-input" placeholder="leave blank for open AP" type="text">
    </div>
  </div>
  <div class="form-group" style="font-size:12px;color:var(--muted);margin-top:4px">
    AP IP: 192.168.69.1 &nbsp;|&nbsp; DHCP: .10–.100 &nbsp;|&nbsp; DNS → all redirected to AP
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-red" onclick="rogueStart()">&#9889; START AP</button>
    <button class="btn btn-muted btn-sm" onclick="rogueStop()">&#9632; STOP</button>
  </div>
</div>

<!-- Connected Clients -->
<div class="card">
  <div class="section-title">CONNECTED CLIENTS <span id="ra-client-count" class="badge badge-found" style="display:none"></span></div>
  <div id="ra-client-table" class="table-wrap">
    <div class="empty">No clients connected</div>
  </div>
</div>

<!-- Beacon Flood -->
<div class="card">
  <div class="section-title">BEACON FLOOD (MDK4)</div>
  <div class="status-row" style="margin-bottom:8px">
    <div class="dot" id="beacon-dot"></div>
    <span id="beacon-status-txt">IDLE</span>
  </div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="beacon-iface" class="form-input"></select>
    </div>
    <div class="form-group">
      <label class="form-label">CHANNEL</label>
      <input id="beacon-channel" class="form-input" type="number" value="6" min="1" max="13">
    </div>
  </div>
  <div class="form-group">
    <label class="form-label">CUSTOM SSIDs (one per line, blank = random)</label>
    <textarea id="beacon-ssids" class="form-input" rows="3" style="resize:vertical;font-family:var(--font-mono);font-size:13px" placeholder="HomeNetwork&#10;CoffeeShop_WiFi&#10;FBI Surveillance Van"></textarea>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-orange" onclick="beaconStart()">&#9729; FLOOD</button>
    <button class="btn btn-muted btn-sm" onclick="beaconStop()">&#9632; STOP</button>
  </div>
</div>`;

    const ifaces = (getStatus() || {}).interfaces;
    _populateRAIfaces(ifaces);
    updateRogueUI(getStatus());
    refreshRAClients();
}

function _populateRAIfaces(ifaces) {
    const list = (ifaces && ifaces.length) ? ifaces : ['wlan0mon', 'wlan1mon', 'wlan2mon', 'wlan0open', 'wlan0mgmt'];
    ['ra-iface', 'beacon-iface'].forEach(id => {
        const sel = document.getElementById(id);
        if (!sel) return;
        const cur = sel.value;
        sel.innerHTML = list.map(i => `<option value="${esc(i)}">${esc(i)}</option>`).join('');
        if (list.includes(cur)) sel.value = cur;
    });
}

function renderRAClients(clients) {
    const el    = document.getElementById('ra-client-table');
    const badge = document.getElementById('ra-client-count');
    if (!el) return;
    if (!clients || !clients.length) {
        el.innerHTML = '<div class="empty">No clients connected yet</div>';
        if (badge) badge.style.display = 'none';
        return;
    }
    if (badge) { badge.textContent = clients.length; badge.style.display = 'inline-block'; }
    el.innerHTML = `
<table class="data-table">
<thead><tr><th>MAC</th><th>IP</th><th>HOSTNAME</th></tr></thead>
<tbody>
  ${clients.map(c => `
  <tr>
    <td style="font-size:12px">${esc(c.mac)}</td>
    <td style="color:var(--cyan)">${esc(c.ip)}</td>
    <td style="color:var(--muted);font-size:12px">${esc(c.hostname || '—')}</td>
  </tr>`).join('')}
</tbody>
</table>`;
}

async function rogueStart() {
    const ssid     = (document.getElementById('ra-ssid').value || '').trim() || 'FreeWiFi';
    const channel  = parseInt(document.getElementById('ra-channel').value) || 6;
    const iface    = document.getElementById('ra-iface').value;
    const password = (document.getElementById('ra-password').value || '').trim();
    const res = await api('/api/rogueap/start', {
        method: 'POST',
        body: JSON.stringify({ ssid, channel, iface, password }),
    });
    if (res && res.ok) toast(`Rogue AP "${ssid}" starting...`, 'warn');
    else               toast((res && res.msg) || 'Failed', 'error');
}

async function rogueStop() {
    await api('/api/rogueap/stop', { method: 'POST', body: '{}' });
    toast('Rogue AP stopped', 'info');
}

async function beaconStart() {
    const iface   = document.getElementById('beacon-iface').value;
    const channel = parseInt(document.getElementById('beacon-channel').value) || 6;
    const ssids   = document.getElementById('beacon-ssids').value || '';
    const res = await api('/api/beacon/start', {
        method: 'POST',
        body: JSON.stringify({ iface, channel, ssids }),
    });
    if (res && res.ok) toast('Beacon flood started', 'warn');
    else               toast((res && res.msg) || 'Failed', 'error');
}

async function beaconStop() {
    await api('/api/beacon/stop', { method: 'POST', body: '{}' });
    toast('Beacon flood stopped', 'info');
}

async function refreshRAClients() {
    const res = await api('/api/rogueap/clients');
    if (res && res.clients) renderRAClients(res.clients);
}

function updateRogueUI(s) {
    if (!s) return;
    if (s.interfaces) _populateRAIfaces(s.interfaces);

    const raDot  = document.getElementById('ra-dot');
    const raTxt  = document.getElementById('ra-status-txt');
    const bDot   = document.getElementById('beacon-dot');
    const bTxt   = document.getElementById('beacon-status-txt');

    if (raDot) raDot.className = s.rogueap_running ? 'dot attacking' : 'dot';
    if (raTxt) {
        raTxt.textContent = s.rogueap_running ? `ONLINE: "${s.rogueap_ssid || ''}"` : 'IDLE';
        raTxt.style.color = s.rogueap_running ? '#ff2020' : '';
    }
    if (bDot) bDot.className = s.beacon_running ? 'dot active' : 'dot';
    if (bTxt) {
        bTxt.textContent = s.beacon_running ? 'FLOODING...' : 'IDLE';
        bTxt.style.color = s.beacon_running ? '#ffcc00' : '';
    }
}

let _raPollTimer = null;

function _startRAPoll() {
    _stopRAPoll();
    _raPollTimer = setInterval(refreshRAClients, 5000);
}

function _stopRAPoll() {
    if (_raPollTimer) { clearInterval(_raPollTimer); _raPollTimer = null; }
}

registerTab('rogueap', {
    onActivate:   () => { buildRogueAP(); _startRAPoll(); },
    onDeactivate: _stopRAPoll,
    onStatus:     updateRogueUI,
});

// Add orange button style if not in CSS
(function() {
    if (!document.getElementById('rogueap-style')) {
        const s = document.createElement('style');
        s.id = 'rogueap-style';
        s.textContent = '.btn-orange{background:#1a0800;border-color:#ff8800;color:#ff8800}.btn-orange:hover{background:#ff8800;color:#000}';
        document.head.appendChild(s);
    }
})();

window.rogueStart     = rogueStart;
window.rogueStop      = rogueStop;
window.beaconStart    = beaconStart;
window.beaconStop     = beaconStop;
window.refreshRAClients = refreshRAClients;
