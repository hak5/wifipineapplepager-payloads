/* capture.js — Packet Capture + PMKID + Handshake Conversion */
'use strict';

function buildCapture() {
    const el = document.getElementById('tab-capture');
    el.innerHTML = `
<div class="section-title">// PACKET CAPTURE</div>

<div class="status-row">
  <div class="dot" id="cap-dot"></div>
  <span id="cap-status-txt">IDLE</span>
</div>

<!-- tcpdump -->
<div class="card">
  <div class="section-title">TCPDUMP CAPTURE</div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="cap-iface" class="form-input"></select>
    </div>
    <div class="form-group">
      <label class="form-label">DURATION (s)</label>
      <input id="cap-duration" class="form-input" type="number" value="60" min="10" max="600">
    </div>
  </div>
  <div class="form-group">
    <label class="form-label">BPF FILTER (blank = all traffic)</label>
    <input id="cap-filter" class="form-input" type="text"
           placeholder="e.g. port 80  or  host 192.168.1.1  or  tcp">
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-green" onclick="captureStart()">&#9654; CAPTURE</button>
    <button class="btn btn-muted btn-sm" onclick="captureStop()">&#9632; STOP</button>
  </div>
</div>

<!-- PMKID -->
<div class="card">
  <div class="section-title">PMKID CAPTURE (HCXDUMPTOOL)</div>
  <div class="status-row" style="margin-bottom:8px">
    <div class="dot" id="pmkid-dot"></div>
    <span id="pmkid-status-txt">IDLE</span>
  </div>
  <div class="grid-2">
    <div class="form-group">
      <label class="form-label">INTERFACE</label>
      <select id="pmkid-iface" class="form-input"></select>
    </div>
    <div class="form-group">
      <label class="form-label">DURATION (s)</label>
      <input id="pmkid-duration" class="form-input" type="number" value="60" min="10" max="300">
    </div>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-red" onclick="pmkidStart()">&#9889; START</button>
    <button class="btn btn-muted btn-sm" onclick="pmkidStop()">&#9632; STOP</button>
  </div>
</div>

<!-- Capture Files -->
<div class="card">
  <div class="section-title">CAPTURE FILES <span id="cap-count" class="badge badge-found" style="display:none"></span></div>
  <div style="margin-bottom:8px">
    <button class="btn btn-muted btn-sm" onclick="refreshCaptures()">&#8635; REFRESH</button>
  </div>
  <div id="cap-table" class="table-wrap">
    <div class="empty">No captures yet</div>
  </div>
</div>`;

    _populateCaptureIfaces((getStatus() || {}).interfaces);
    refreshCaptures();
}

function _populateCaptureIfaces(ifaces) {
    const list = (ifaces && ifaces.length) ? ifaces : ['wlan0mon', 'wlan1mon', 'wlan2mon', 'wlan0open', 'wlan0mgmt'];
    ['cap-iface', 'pmkid-iface'].forEach(id => {
        const sel = document.getElementById(id);
        if (!sel) return;
        const cur = sel.value;
        sel.innerHTML = list.map(i => `<option value="${esc(i)}">${esc(i)}</option>`).join('');
        if (list.includes(cur)) sel.value = cur;
    });
}

function _fmtCapSize(b) {
    if (b < 1024)    return b + 'B';
    if (b < 1048576) return (b / 1024).toFixed(1) + 'K';
    return (b / 1048576).toFixed(1) + 'M';
}

function renderCaptureFiles(files) {
    const el    = document.getElementById('cap-table');
    const badge = document.getElementById('cap-count');
    if (!el) return;
    if (!files || !files.length) {
        el.innerHTML = '<div class="empty">No captures yet</div>';
        if (badge) badge.style.display = 'none';
        return;
    }
    if (badge) { badge.textContent = files.length; badge.style.display = 'inline-block'; }
    el.innerHTML = `
<table class="data-table">
<thead><tr><th>FILE</th><th>SIZE</th><th>ACTIONS</th></tr></thead>
<tbody>
  ${files.map(f => `
  <tr>
    <td style="font-size:11px;max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"
        title="${esc(f.name)}">${esc(f.name)}</td>
    <td style="font-size:11px;white-space:nowrap">${esc(_fmtCapSize(f.size))}</td>
    <td style="white-space:nowrap">
      <a class="btn btn-sm btn-muted"
         href="/api/download/${encodeURIComponent(f.name)}"
         download="${esc(f.name)}"
         title="Download">&#8595;</a>
      <button class="btn btn-sm btn-orange"
              onclick="convertCapture(${JSON.stringify(f.name)})"
              title="Convert to hashcat .22000">.22000</button>
    </td>
  </tr>`).join('')}
</tbody>
</table>`;
}

async function captureStart() {
    const iface       = document.getElementById('cap-iface').value;
    const duration    = parseInt(document.getElementById('cap-duration').value) || 60;
    const filter_expr = (document.getElementById('cap-filter').value || '').trim();
    const res = await api('/api/capture/start', {
        method: 'POST', body: JSON.stringify({ iface, duration, filter_expr }),
    });
    if (res && res.ok) toast(`Capturing on ${iface}...`, 'success');
    else               toast((res && res.msg) || 'Failed', 'error');
}

async function captureStop() {
    await api('/api/capture/stop', { method: 'POST', body: '{}' });
    toast('Capture stopped', 'info');
}

async function pmkidStart() {
    const iface    = document.getElementById('pmkid-iface').value;
    const duration = parseInt(document.getElementById('pmkid-duration').value) || 60;
    const res = await api('/api/pmkid/start', {
        method: 'POST', body: JSON.stringify({ iface, duration }),
    });
    if (res && res.ok) toast(`PMKID capture on ${iface}...`, 'warn');
    else               toast((res && res.msg) || 'Failed', 'error');
}

async function pmkidStop() {
    await api('/api/pmkid/stop', { method: 'POST', body: '{}' });
    toast('PMKID capture stopped', 'info');
}

async function convertCapture(name) {
    toast(`Converting ${name}\u2026`, 'info');
    const res = await api('/api/loot/convert', {
        method: 'POST', body: JSON.stringify({ file: name }),
    });
    if (res && res.ok) {
        toast(`Converted \u2192 ${res.out_file || 'done'}`, 'success');
        refreshCaptures();
    } else {
        toast((res && res.msg) || 'Conversion failed', 'error');
    }
}

async function refreshCaptures() {
    const res = await api('/api/captures');
    if (res && res.files) renderCaptureFiles(res.files);
}

function updateCaptureUI(s) {
    if (!s) return;
    if (s.interfaces) _populateCaptureIfaces(s.interfaces);

    const dot  = document.getElementById('cap-dot');
    const txt  = document.getElementById('cap-status-txt');
    const pdot = document.getElementById('pmkid-dot');
    const ptxt = document.getElementById('pmkid-status-txt');

    if (dot) dot.className = s.capturing ? 'dot active' : 'dot';
    if (txt) {
        txt.textContent = s.capturing ? 'CAPTURING...' : 'IDLE';
        txt.style.color = s.capturing ? '#ffcc00' : '';
    }
    if (pdot) pdot.className = s.pmkid_running ? 'dot attacking' : 'dot';
    if (ptxt) {
        ptxt.textContent = s.pmkid_running ? 'RUNNING...' : 'IDLE';
        ptxt.style.color = s.pmkid_running ? '#ff2020' : '';
    }
}

let _capPollTimer = null;

function _startCapPoll() {
    _stopCapPoll();
    _capPollTimer = setInterval(refreshCaptures, 6000);
}

function _stopCapPoll() {
    if (_capPollTimer) { clearInterval(_capPollTimer); _capPollTimer = null; }
}

registerTab('capture', {
    onActivate:   () => { buildCapture(); _startCapPoll(); },
    onDeactivate: _stopCapPoll,
    onStatus:     updateCaptureUI,
});

// Inject .btn-orange style if rogueap.js hasn't already
(function() {
    if (!document.getElementById('rogueap-style') && !document.getElementById('capture-style')) {
        const s = document.createElement('style');
        s.id = 'capture-style';
        s.textContent = '.btn-orange{background:#1a0800;border-color:#ff8800;color:#ff8800}.btn-orange:hover{background:#ff8800;color:#000}';
        document.head.appendChild(s);
    }
})();

window.captureStart    = captureStart;
window.captureStop     = captureStop;
window.pmkidStart      = pmkidStart;
window.pmkidStop       = pmkidStop;
window.convertCapture  = convertCapture;
window.refreshCaptures = refreshCaptures;
