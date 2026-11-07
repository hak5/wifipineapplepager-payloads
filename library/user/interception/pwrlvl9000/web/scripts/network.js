/* network.js — Network / port scanner */
'use strict';

function buildNetwork() {
    const el = document.getElementById('tab-network');
    el.innerHTML = `
<div class="section-title">// NETWORK SCANNER</div>

<div class="status-row">
  <div class="dot" id="net-dot"></div>
  <span id="net-status-txt">IDLE</span>
</div>

<div class="card">
  <div class="section-title">TARGET</div>
  <div class="form-group">
    <label class="form-label">HOST / SUBNET</label>
    <input id="net-target" class="form-input" type="text"
           placeholder="192.168.1.1 or 192.168.1.0/24">
  </div>
  <div class="form-group">
    <label class="form-label">PORT RANGE</label>
    <select id="net-ports" class="form-input">
      <option value="common">Common ports (21,22,80,443,3306...)</option>
      <option value="quick">Quick (21,22,23,80,443,445,3306,8080)</option>
      <option value="1-1024">1-1024</option>
      <option value="1-65535">Full (1-65535, slow)</option>
    </select>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-green" onclick="netScan()">&#x2022; SCAN</button>
    <button class="btn btn-muted btn-sm" onclick="netStop()">&#9632; STOP</button>
  </div>
</div>

<!-- Quick ARP table -->
<div class="card">
  <div class="section-title">ARP TABLE</div>
  <div id="arp-table">
    <button class="btn btn-muted btn-sm" onclick="loadArp()">READ ARP CACHE</button>
  </div>
</div>

<!-- Results -->
<div id="net-results-wrap" style="display:none">
  <div class="section-title">OPEN PORTS</div>
  <div id="net-results"></div>
</div>`;

    updateNetUI(getStatus());
    loadNetResults();
}

async function loadArp() {
    const res = await api('/api/terminal', {
        method: 'POST',
        body:   JSON.stringify({ cmd: 'cat /proc/net/arp' }),
    });
    const el = document.getElementById('arp-table');
    if (!el) return;
    if (res && res.output) {
        const lines = res.output.trim().split('\n');
        let html = '<table class="data-table"><thead><tr>';
        // Parse header
        const hdr = lines[0].split(/\s{2,}/);
        hdr.forEach(h => { html += `<th>${h.trim()}</th>`; });
        html += '</tr></thead><tbody>';
        lines.slice(1).forEach(line => {
            const cols = line.trim().split(/\s+/);
            if (cols.length >= 4 && cols[2] !== '0x0') {
                html += '<tr>' + cols.slice(0, 6).map(c => `<td>${c}</td>`).join('') + '</tr>';
            }
        });
        html += '</tbody></table>';
        el.innerHTML = html;
    } else {
        el.innerHTML = '<div class="empty">Failed to read ARP table</div>';
    }
}

async function loadNetResults() {
    const res = await api('/api/network/results');
    if (res && res.results && res.results.length) {
        renderNetResults(res.results);
    }
}

function renderNetResults(results) {
    const wrap = document.getElementById('net-results-wrap');
    const el   = document.getElementById('net-results');
    if (!el || !wrap) return;
    wrap.style.display = 'block';

    if (!results || results.length === 0) {
        el.innerHTML = '<div class="empty">No open ports found</div>';
        return;
    }

    let html = '';
    results.forEach(r => {
        html += `<div class="card" style="margin-bottom:8px">
<div style="color:var(--cyan);font-size:16px;margin-bottom:8px">&#x25B6; ${r.host}</div>`;
        if (r.ports && r.ports.length) {
            html += '<table class="data-table"><thead><tr><th>PORT</th><th>SERVICE</th><th>BANNER</th></tr></thead><tbody>';
            r.ports.forEach(p => {
                const svcCls = ['22','21'].includes(String(p.port)) ? 'badge-warn'
                             : ['80','8080','443'].includes(String(p.port)) ? 'badge-found'
                             : p.port === 3306 || p.port === 5432 ? 'badge-miss'
                             : 'badge-enc';
                html += `<tr>
  <td><span class="badge ${svcCls}">${esc(p.port)}</span></td>
  <td style="font-size:12px">${esc(p.service)}</td>
  <td style="font-size:11px;color:var(--muted);max-width:180px;overflow:hidden;text-overflow:ellipsis">${esc(p.banner || '')}</td>
</tr>`;
            });
            html += '</tbody></table>';
        } else {
            html += '<div class="empty" style="padding:8px">No open ports</div>';
        }
        html += '</div>';
    });
    el.innerHTML = html;
}

async function netScan() {
    const target = (document.getElementById('net-target').value || '').trim();
    const ports  = document.getElementById('net-ports').value;
    if (!target) {
        toast('Enter a target host or subnet', 'error');
        return;
    }
    const res = await api('/api/network/scan', {
        method: 'POST',
        body:   JSON.stringify({ target, ports }),
    });
    if (res && res.ok) {
        toast(`Scanning ${target}...`, 'success');
        const poll = setInterval(async () => {
            const s = getStatus();
            if (!s.net_scanning) {
                clearInterval(poll);
                loadNetResults();
            }
        }, 3000);
    } else {
        toast((res && res.msg) || 'Scan failed', 'error');
    }
}

async function netStop() {
    await api('/api/network/stop', { method: 'POST', body: '{}' });
    toast('Scan stopped', 'info');
}

function updateNetUI(s) {
    if (!s) return;
    const dot = document.getElementById('net-dot');
    const txt = document.getElementById('net-status-txt');
    if (dot) dot.className = 'dot' + (s.net_scanning ? ' active' : '');
    if (txt) {
        txt.textContent = s.net_scanning ? 'SCANNING...' : 'IDLE';
        txt.style.color = s.net_scanning ? '#ffcc00' : '';
    }
}

registerTab('network', {
    onActivate: buildNetwork,
    onStatus:   updateNetUI,
});

window.netScan  = netScan;
window.netStop  = netStop;
window.loadArp  = loadArp;
