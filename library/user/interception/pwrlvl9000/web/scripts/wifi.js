/* wifi.js — WiFi attack controls */
'use strict';

let _wifiAPs = [];

function buildWifi() {
    const el = document.getElementById('tab-wifi');
    el.innerHTML = `
<div class="section-title">// WiFi ATTACK CONSOLE</div>

<!-- Status -->
<div class="status-row">
  <div class="dot" id="wifi-dot"></div>
  <span id="wifi-status-txt">IDLE</span>
</div>

<!-- Scan Controls -->
<div class="card">
  <div class="section-title">SCANNER</div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="wifi-iface" class="form-input"></select>
    </div>
    <div class="form-group">
      <label class="form-label">DURATION (s)</label>
      <input id="wifi-duration" class="form-input" type="number" value="30" min="5" max="120">
    </div>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-green" onclick="wifiScan()">&#9655; SCAN</button>
    <button class="btn btn-muted btn-sm" onclick="wifiStopScan()">&#9632; STOP</button>
    <button class="btn btn-cyan btn-sm" onclick="wifiMonitor(true)">MON ON</button>
    <button class="btn btn-muted btn-sm" onclick="wifiMonitor(false)">MON OFF</button>
  </div>
</div>

<!-- AP Results -->
<div class="card">
  <div class="section-title">ACCESS POINTS <span id="ap-count" class="badge badge-found" style="display:none"></span></div>
  <div id="ap-table" class="table-wrap">
    <div class="empty">No scan data — run scanner first</div>
  </div>
</div>

<!-- Attack Controls -->
<div class="card">
  <div class="section-title">DEAUTH + CAPTURE</div>
  <div id="atk-info" class="attack-info" style="display:none"></div>
  <div class="form-group">
    <label class="form-label">TARGET BSSID</label>
    <input id="atk-bssid" class="form-input" placeholder="AA:BB:CC:DD:EE:FF" type="text">
  </div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">CHANNEL</label>
      <input id="atk-channel" class="form-input" placeholder="6" type="number" min="1" max="165">
    </div>
    <div class="form-group">
      <label class="form-label">BURST (0=∞)</label>
      <input id="atk-count" class="form-input" placeholder="0" type="number" min="0" value="0">
    </div>
  </div>
  <div class="form-group">
    <label class="form-label">INTERFACE</label>
    <select id="atk-iface" class="form-input"></select>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-red" onclick="wifiAttack()">&#9889; ATTACK</button>
    <button class="btn btn-muted btn-sm" onclick="wifiStopAttack()">&#9632; STOP</button>
  </div>
</div>`;

    _populateIfaceSelects((getStatus() || {}).interfaces);
    updateWifiUI(getStatus());
}

function _populateIfaceSelects(ifaces) {
    const list = (ifaces && ifaces.length) ? ifaces : ['wlan0mon', 'wlan1mon', 'wlan2mon', 'wlan0open', 'wlan0mgmt'];
    ['wifi-iface', 'atk-iface'].forEach(id => {
        const sel = document.getElementById(id);
        if (!sel) return;
        const cur = sel.value;
        sel.innerHTML = list.map(i => `<option value="${esc(i)}">${esc(i)}</option>`).join('');
        if (list.includes(cur)) sel.value = cur;
    });
}

function renderAPs(aps) {
    const el    = document.getElementById('ap-table');
    const count = document.getElementById('ap-count');
    if (!el) return;
    _wifiAPs = aps;
    if (!aps || aps.length === 0) {
        el.innerHTML = '<div class="empty">No APs found yet...</div>';
        if (count) count.style.display = 'none';
        return;
    }
    if (count) {
        count.textContent = aps.length + ' APs';
        count.style.display = 'inline-block';
    }
    el.innerHTML = `
<table class="data-table">
<thead><tr>
  <th>BSSID</th><th>CH</th><th>PWR</th><th>ENC</th><th>ESSID</th><th></th>
</tr></thead>
<tbody>
  ${aps.map(ap => {
    const pwr   = parseInt(ap.power) || -100;
    const sigCls = pwr > -50 ? 'sig-hi' : pwr > -70 ? 'sig-md' : 'sig-lo';
    const sigBars = pwr > -50 ? '▂▄▆█' : pwr > -70 ? '▂▄▆_' : '▂___';
    const enc   = ap.enc || 'OPN';
    const encCls = enc.includes('WPA2') ? 'badge-wpa2'
                 : enc.includes('WPA')  ? 'badge-wpa'
                 : 'badge-open';
    return `
    <tr>
      <td style="font-size:12px">${esc(ap.bssid)}</td>
      <td>${esc(ap.channel)}</td>
      <td class="${sigCls}" style="font-size:13px">${sigBars}</td>
      <td><span class="badge ${encCls}">${esc(enc)}</span></td>
      <td style="max-width:120px;overflow:hidden;text-overflow:ellipsis">${ap.essid ? esc(ap.essid) : '&lt;hidden&gt;'}</td>
      <td>
        <button class="btn btn-sm btn-red" onclick="prefillAttack(${JSON.stringify(ap.bssid)},${JSON.stringify(ap.channel)})">ATK</button>
      </td>
    </tr>`;
  }).join('')}
</tbody>
</table>`;
}

function prefillAttack(bssid, channel) {
    const b = document.getElementById('atk-bssid');
    const c = document.getElementById('atk-channel');
    if (b) b.value = bssid;
    if (c) c.value = channel;
    toast(`Target: ${bssid} ch${channel}`, 'info');
}

async function wifiScan() {
    const iface    = document.getElementById('wifi-iface').value;
    const duration = parseInt(document.getElementById('wifi-duration').value) || 30;
    const res = await api('/api/wifi/scan', {
        method: 'POST',
        body:   JSON.stringify({ iface, duration }),
    });
    if (res && res.ok) {
        toast(`Scanning ${iface} for ${duration}s...`, 'success');
    } else {
        toast((res && res.msg) || 'Scan failed', 'error');
    }
}

async function wifiStopScan() {
    await api('/api/wifi/stop_scan', { method: 'POST', body: '{}' });
    toast('Scan stopped', 'info');
}

async function wifiMonitor(enable) {
    const iface = document.getElementById('wifi-iface').value;
    const res   = await api('/api/wifi/monitor', {
        method: 'POST',
        body:   JSON.stringify({ iface, enable }),
    });
    if (res && res.ok) toast(res.msg, 'success');
    else               toast('Monitor toggle failed', 'error');
}

async function wifiAttack() {
    const bssid   = (document.getElementById('atk-bssid').value || '').trim();
    const channel = document.getElementById('atk-channel').value || 6;
    const count   = parseInt(document.getElementById('atk-count').value) || 0;
    const iface   = document.getElementById('atk-iface').value;

    if (!bssid || !/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(bssid)) {
        toast('Enter valid BSSID (AA:BB:CC:DD:EE:FF)', 'error');
        return;
    }
    const res = await api('/api/wifi/attack', {
        method: 'POST',
        body:   JSON.stringify({ bssid, channel, iface, count }),
    });
    if (res && res.ok) {
        toast(`Attack started → ${bssid}`, 'warn');
    } else {
        toast((res && res.msg) || 'Attack failed', 'error');
    }
}

async function wifiStopAttack() {
    await api('/api/wifi/stop_attack', { method: 'POST', body: '{}' });
    toast('Attack stopped', 'info');
}

function updateWifiUI(s) {
    if (!s) return;
    if (s.interfaces) _populateIfaceSelects(s.interfaces);
    const dot = document.getElementById('wifi-dot');
    const txt = document.getElementById('wifi-status-txt');
    const inf = document.getElementById('atk-info');

    if (dot) {
        if (s.wifi_attacking) {
            dot.className = 'dot attacking';
        } else if (s.wifi_scanning) {
            dot.className = 'dot active';
        } else {
            dot.className = 'dot';
        }
    }
    if (txt) {
        if (s.wifi_attacking) {
            txt.textContent = `ATTACKING → ${s.attack_bssid || ''}`;
            txt.style.color = '#ff2020';
        } else if (s.wifi_scanning) {
            txt.textContent = `SCANNING ${s.scan_iface || ''}...`;
            txt.style.color = '#ffcc00';
        } else {
            txt.textContent = 'IDLE';
            txt.style.color = '';
        }
    }
    if (inf) {
        if (s.wifi_attacking) {
            inf.style.display = 'block';
            inf.textContent   = `ACTIVE TARGET: ${s.attack_bssid} on ${s.attack_iface}`;
        } else {
            inf.style.display = 'none';
        }
    }
}

// Poll for AP results when wifi tab is active
let _wifiPollTimer = null;

function _startWifiPoll() {
    _stopWifiPoll();
    _wifiPollTimer = setInterval(async () => {
        const res = await api('/api/wifi/results');
        if (res && res.aps) renderAPs(res.aps);
    }, 4000);
}

function _stopWifiPoll() {
    if (_wifiPollTimer) { clearInterval(_wifiPollTimer); _wifiPollTimer = null; }
}

registerTab('wifi', {
    onActivate:   () => { buildWifi(); _startWifiPoll(); },
    onDeactivate: _stopWifiPoll,
    onStatus:     updateWifiUI,
});

window.wifiScan        = wifiScan;
window.wifiStopScan    = wifiStopScan;
window.wifiMonitor     = wifiMonitor;
window.wifiAttack      = wifiAttack;
window.wifiStopAttack  = wifiStopAttack;
window.prefillAttack   = prefillAttack;
