/* webscan.js — Web application scanner */
'use strict';

function buildWebscan() {
    const el = document.getElementById('tab-webscan');
    el.innerHTML = `
<div class="section-title">// WEB SCANNER</div>

<div class="status-row">
  <div class="dot" id="ws-dot"></div>
  <span id="ws-status-txt">IDLE</span>
</div>

<div class="card">
  <div class="section-title">TARGET</div>
  <div class="form-group">
    <label class="form-label">URL</label>
    <input id="ws-url" class="form-input" type="text" placeholder="http://192.168.1.1 or https://target.com">
  </div>
  <div class="form-group">
    <label class="form-label">PATH PROBE</label>
    <select id="ws-paths" class="form-input">
      <option value="true">Yes — probe common paths</option>
      <option value="false">No — headers only</option>
    </select>
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-cyan" onclick="wsScan()">&#x2316; SCAN</button>
    <button class="btn btn-muted btn-sm" onclick="wsStop()">&#9632; STOP</button>
  </div>
</div>

<div class="card" id="ws-results-card" style="display:none">
  <div class="section-title">RESULTS</div>
  <div id="ws-results"></div>
</div>`;

    updateWsUI(getStatus());
    // Load last results if any
    loadWsResults();
}

async function loadWsResults() {
    const res = await api('/api/webscan/results');
    if (res && res.results && Object.keys(res.results).length) {
        renderWsResults(res.results);
    }
}

function renderWsResults(findings) {
    const card = document.getElementById('ws-results-card');
    const el   = document.getElementById('ws-results');
    if (!el || !card) return;
    card.style.display = 'block';

    let html = '';

    // Status
    if (findings.status) {
        const cls = findings.status < 300 ? 'badge-found'
                  : findings.status < 400 ? 'badge-warn'
                  : 'badge-miss';
        html += `<div class="mb-8">STATUS: <span class="badge ${cls}">${findings.status}</span></div>`;
    }

    // Headers
    if (findings.headers) {
        html += '<div class="section-title" style="margin-top:12px">RESPONSE HEADERS</div>';
        html += '<table class="data-table"><tbody>';
        for (const [k, v] of Object.entries(findings.headers)) {
            html += `<tr><td style="color:var(--muted);font-size:12px">${esc(k)}</td><td style="font-size:12px">${esc(String(v).substring(0,80))}</td></tr>`;
        }
        html += '</tbody></table>';
    }

    // Interesting findings
    if (findings.interesting && findings.interesting.length) {
        html += '<div class="section-title" style="margin-top:12px">FINDINGS</div>';
        findings.interesting.forEach(f => {
            const cls = f.startsWith('MISSING') ? 'badge-miss' : 'badge-warn';
            html += `<div style="margin:3px 0"><span class="badge ${cls}">${esc(f)}</span></div>`;
        });
    }

    // Body patterns
    if (findings.body_patterns && findings.body_patterns.length) {
        html += '<div class="section-title" style="margin-top:12px">BODY PATTERNS</div>';
        findings.body_patterns.forEach(p => {
            html += `<div style="margin:3px 0"><span class="badge badge-miss">&#9888; ${esc(p.toUpperCase())}</span></div>`;
        });
    }

    // Path probe results
    if (findings.paths && findings.paths.length) {
        html += '<div class="section-title" style="margin-top:12px">DISCOVERED PATHS</div>';
        html += '<table class="data-table"><thead><tr><th>PATH</th><th>STATUS</th></tr></thead><tbody>';
        findings.paths.forEach(p => {
            const cls = p.status === 200 ? 'badge-found'
                      : p.status < 400  ? 'badge-warn'
                      : 'badge-miss';
            html += `<tr><td style="font-size:12px">${esc(p.path)}</td><td><span class="badge ${cls}">${esc(p.status)}</span></td></tr>`;
        });
        html += '</tbody></table>';
    }

    if (!html) {
        html = '<div class="empty">No findings yet</div>';
    }

    el.innerHTML = html;
}

async function wsScan() {
    const url   = (document.getElementById('ws-url').value || '').trim();
    const paths = document.getElementById('ws-paths').value === 'true';
    if (!url) {
        toast('Enter a target URL', 'error');
        return;
    }
    const res = await api('/api/webscan', {
        method: 'POST',
        body:   JSON.stringify({ url, check_paths: paths }),
    });
    if (res && res.ok) {
        toast(`Scanning ${url}...`, 'success');
        // Poll for results
        const poll = setInterval(async () => {
            const s = getStatus();
            if (!s.web_scanning) {
                clearInterval(poll);
                loadWsResults();
            }
        }, 3000);
    } else {
        toast((res && res.msg) || 'Scan failed', 'error');
    }
}

async function wsStop() {
    await api('/api/webscan/stop', { method: 'POST', body: '{}' });
    toast('Scan stopped', 'info');
}

function updateWsUI(s) {
    if (!s) return;
    const dot = document.getElementById('ws-dot');
    const txt = document.getElementById('ws-status-txt');
    if (dot) dot.className = 'dot' + (s.web_scanning ? ' active' : '');
    if (txt) {
        txt.textContent = s.web_scanning ? 'SCANNING...' : 'IDLE';
        txt.style.color = s.web_scanning ? '#ffcc00' : '';
    }
}

registerTab('webscan', {
    onActivate: buildWebscan,
    onStatus:   updateWsUI,
});

window.wsScan = wsScan;
window.wsStop = wsStop;
