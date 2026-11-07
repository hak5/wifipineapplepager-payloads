/* loot.js — Captured handshakes + cracked passwords */
'use strict';

let _lootSub = 'captures';

function buildLoot() {
    const el = document.getElementById('tab-loot');
    el.innerHTML = `
<div class="section-title">// LOOT VAULT</div>

<div style="display:flex;gap:4px;margin-bottom:12px">
  <button class="btn ${_lootSub === 'captures' ? 'btn-green' : 'btn-muted'} btn-sm"
          onclick="lootTab('captures')">CAPTURES</button>
  <button class="btn ${_lootSub === 'cracked' ? 'btn-green' : 'btn-muted'} btn-sm"
          onclick="lootTab('cracked')">CRACKED</button>
  <button class="btn btn-muted btn-sm" onclick="loadLoot()">&#8635; REFRESH</button>
</div>

<div id="loot-captures" class="${_lootSub === 'captures' ? '' : 'hidden'}">
  <div class="empty">Loading...</div>
</div>
<div id="loot-cracked" class="${_lootSub === 'cracked' ? '' : 'hidden'}">
  <div class="empty">Loading...</div>
</div>

<!-- Crack dialog -->
<div class="card mt-12" id="crack-card" style="display:none">
  <div class="section-title">CRACK HANDSHAKE</div>
  <div class="form-group">
    <label class="form-label">FILE</label>
    <input id="crack-file" class="form-input" type="text" readonly>
  </div>
  <div class="form-group">
    <label class="form-label">WORDLIST</label>
    <input id="crack-wordlist" class="form-input" type="text"
           value="/usr/share/wordlists/rockyou.txt"
           placeholder="/path/to/wordlist.txt">
  </div>
  <div class="btn-group mt-8">
    <button class="btn btn-red" onclick="startCrack()">&#9889; CRACK IT</button>
    <button class="btn btn-muted btn-sm" onclick="hideCrackCard()">CANCEL</button>
  </div>
</div>`;

    loadLoot();
}

function lootTab(tab) {
    _lootSub = tab;
    const captures = document.getElementById('loot-captures');
    const cracked  = document.getElementById('loot-cracked');
    if (captures) captures.className = tab === 'captures' ? '' : 'hidden';
    if (cracked)  cracked.className  = tab === 'cracked'  ? '' : 'hidden';
    document.querySelectorAll('#tab-loot .btn').forEach(b => {
        if (b.textContent.trim().toLowerCase() === tab.toLowerCase()) {
            b.className = 'btn btn-green btn-sm';
        } else if (!b.getAttribute('onclick').includes('loadLoot')) {
            b.className = 'btn btn-muted btn-sm';
        }
    });
}

async function loadLoot() {
    const res = await api('/api/handshakes');
    if (!res) {
        document.getElementById('loot-captures').innerHTML =
            '<div class="empty">Failed to load loot</div>';
        return;
    }
    renderCaptures(res.files || []);
    renderCracked(res.files || []);
}

function fmtSize(b) {
    if (b < 1024)       return b + 'B';
    if (b < 1024*1024)  return (b/1024).toFixed(1) + 'K';
    return (b/1024/1024).toFixed(1) + 'M';
}

function fmtTime(ts) {
    return new Date(ts * 1000).toLocaleString();
}

function renderCaptures(files) {
    const el = document.getElementById('loot-captures');
    if (!el) return;
    if (!files.length) {
        el.innerHTML = '<div class="empty">No captures yet — run WiFi attack to capture handshakes</div>';
        return;
    }
    el.innerHTML = `
<table class="data-table">
<thead><tr>
  <th>FILE</th><th>SIZE</th><th>CAPTURED</th><th>STATUS</th><th></th>
</tr></thead>
<tbody>
  ${files.map(f => `
  <tr>
    <td style="font-size:11px;max-width:120px;overflow:hidden;text-overflow:ellipsis">${esc(f.name)}</td>
    <td style="font-size:11px">${esc(fmtSize(f.size))}</td>
    <td style="font-size:11px">${esc(fmtTime(f.mtime))}</td>
    <td>${f.cracked
      ? '<span class="badge badge-found">&#10003; CRACKED</span>'
      : '<span class="badge badge-warn">UNCRKD</span>'}</td>
    <td style="white-space:nowrap">
      <button class="btn btn-sm btn-red" onclick="openCrack(${JSON.stringify(f.name)})">CRACK</button>
      <button class="btn btn-sm btn-orange" onclick="convertLoot(${JSON.stringify(f.name)})" title="Convert to .22000 for hashcat">.22k</button>
    </td>
  </tr>`).join('')}
</tbody>
</table>`;
}

async function convertLoot(name) {
    toast(`Converting ${name}\u2026`, 'info');
    const res = await api('/api/loot/convert', {
        method: 'POST', body: JSON.stringify({ file: name }),
    });
    if (res && res.ok) toast(`Converted \u2192 ${res.out_file || 'done'}`, 'success');
    else               toast((res && res.msg) || 'Conversion failed', 'error');
}

function renderCracked(files) {
    const el = document.getElementById('loot-cracked');
    if (!el) return;
    const cracked = files.filter(f => f.cracked);
    if (!cracked.length) {
        el.innerHTML = '<div class="empty">No cracked passwords yet</div>';
        return;
    }
    el.innerHTML = `
<table class="data-table">
<thead><tr><th>FILE</th><th>PASSWORD</th></tr></thead>
<tbody>
  ${cracked.map(f => `
  <tr>
    <td style="font-size:11px">${esc(f.name)}</td>
    <td style="color:var(--green);letter-spacing:2px">${esc(f.cracked)}</td>
  </tr>`).join('')}
</tbody>
</table>`;
}

function openCrack(name) {
    const card = document.getElementById('crack-card');
    const file = document.getElementById('crack-file');
    if (card) card.style.display = 'block';
    if (file) file.value = name;
}

function hideCrackCard() {
    const card = document.getElementById('crack-card');
    if (card) card.style.display = 'none';
}

async function startCrack() {
    const file     = (document.getElementById('crack-file').value     || '').trim();
    const wordlist = (document.getElementById('crack-wordlist').value || '').trim();
    if (!file) {
        toast('No file selected', 'error');
        return;
    }
    if (!wordlist) {
        toast('Enter wordlist path', 'error');
        return;
    }
    // Quick check: verify wordlist exists on device
    const chk = await api('/api/terminal', {
        method: 'POST',
        body:   JSON.stringify({ cmd: `test -f ${JSON.stringify(wordlist)} && echo EXISTS || echo MISSING` }),
    });
    if (chk && chk.output && chk.output.includes('MISSING')) {
        toast(`Wordlist not found: ${wordlist}`, 'error');
        return;
    }
    const res = await api('/api/wifi/crack', {
        method: 'POST',
        body:   JSON.stringify({ file, wordlist }),
    });
    if (res && res.ok) {
        toast(`Cracking ${file} — watch event log`, 'warn');
        hideCrackCard();
    } else {
        toast((res && res.msg) || 'Crack failed to start', 'error');
    }
}

// Ensure .btn-orange style exists (may be injected by rogueap.js or capture.js)
(function() {
    if (!document.getElementById('rogueap-style') && !document.getElementById('capture-style') && !document.getElementById('loot-style')) {
        const s = document.createElement('style');
        s.id = 'loot-style';
        s.textContent = '.btn-orange{background:#1a0800;border-color:#ff8800;color:#ff8800}.btn-orange:hover{background:#ff8800;color:#000}';
        document.head.appendChild(s);
    }
})();

// Refresh loot on activate
registerTab('loot', {
    onActivate: buildLoot,
});

window.lootTab       = lootTab;
window.loadLoot      = loadLoot;
window.openCrack     = openCrack;
window.hideCrackCard = hideCrackCard;
window.startCrack    = startCrack;
window.convertLoot   = convertLoot;
