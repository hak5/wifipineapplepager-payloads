/* terminal.js — Root shell terminal */
'use strict';

const _hist  = [];
let   _hIdx  = -1;

const QUICK_CMDS = [
    { label: 'Interfaces',   cmd: 'iw dev' },
    { label: 'Routes',       cmd: 'ip route' },
    { label: 'Processes',    cmd: 'ps' },
    { label: 'ARP',          cmd: 'cat /proc/net/arp' },
    { label: 'aircrack-ng',  cmd: 'which aircrack-ng && aircrack-ng --version 2>&1 | head -2' },
    { label: 'airodump-ng',  cmd: 'which airodump-ng' },
    { label: 'aireplay-ng',  cmd: 'which aireplay-ng' },
    { label: 'opkg list',    cmd: 'opkg list-installed | grep -i python' },
    { label: 'df -h',        cmd: 'df -h' },
    { label: 'free',         cmd: 'free' },
    { label: 'uptime',       cmd: 'uptime' },
    { label: 'iwconfig',     cmd: 'iwconfig 2>&1' },
];

function buildTerminal() {
    const el = document.getElementById('tab-terminal');
    el.innerHTML = `
<div class="section-title">// ROOT SHELL</div>
<div style="color:var(--muted);font-size:13px;letter-spacing:2px;margin-bottom:10px">
  Commands run as root on the Pager — use with care
</div>

<!-- Quick commands -->
<div class="card" style="padding:10px">
  <div class="section-title">QUICK COMMANDS</div>
  <div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:4px">
    ${QUICK_CMDS.map(q =>
        `<button class="btn btn-muted btn-sm" onclick="termQuick(${JSON.stringify(q.cmd)})">${q.label}</button>`
    ).join('')}
  </div>
</div>

<!-- Terminal output -->
<div class="term-output" id="term-out">
  <div class="term-cmd" style="color:var(--green-dim)">PWRLVL9000 SHELL — root@pager</div>
  <div class="term-result" style="color:var(--muted)">Type a command or use the quick buttons above.</div>
</div>

<!-- Input row -->
<div class="term-input-row">
  <span class="term-prompt">root@pager:~#</span>
  <input id="term-in" class="term-input" type="text"
         placeholder="command..." autocomplete="off" autocorrect="off"
         autocapitalize="off" spellcheck="false">
  <button class="btn btn-green btn-sm" onclick="termRun()">RUN</button>
  <button class="btn btn-muted btn-sm" onclick="termClear()">CLR</button>
</div>`;

    const inp = document.getElementById('term-in');
    if (inp) {
        inp.addEventListener('keydown', e => {
            if (e.key === 'Enter')     { e.preventDefault(); termRun(); }
            if (e.key === 'ArrowUp')   { e.preventDefault(); termHistNav(1); }
            if (e.key === 'ArrowDown') { e.preventDefault(); termHistNav(-1); }
        });
        inp.focus();
    }
}

function termHistNav(dir) {
    const inp = document.getElementById('term-in');
    if (!inp || !_hist.length) return;
    _hIdx = Math.max(-1, Math.min(_hist.length - 1, _hIdx + dir));
    inp.value = _hIdx >= 0 ? _hist[_hIdx] : '';
}

function termQuick(cmd) {
    const inp = document.getElementById('term-in');
    if (inp) {
        inp.value = cmd;
        inp.focus();
    }
    termRun();
}

function termClear() {
    const out = document.getElementById('term-out');
    if (out) out.innerHTML = '';
}

async function termRun() {
    const inp = document.getElementById('term-in');
    const out = document.getElementById('term-out');
    if (!inp || !out) return;
    const cmd = inp.value.trim();
    if (!cmd) return;

    _hist.unshift(cmd);
    if (_hist.length > 100) _hist.pop();
    _hIdx     = -1;
    inp.value = '';

    // Show command
    const cmdEl  = document.createElement('div');
    cmdEl.className   = 'term-cmd';
    cmdEl.textContent = 'root@pager:~# ' + cmd;
    out.appendChild(cmdEl);

    // Loading indicator
    const loadEl = document.createElement('div');
    loadEl.className   = 'term-result';
    loadEl.style.color = 'var(--muted)';
    loadEl.textContent = '...';
    out.appendChild(loadEl);
    out.scrollTop = out.scrollHeight;

    const res = await api('/api/terminal', {
        method: 'POST',
        body:   JSON.stringify({ cmd }),
    });

    loadEl.remove();

    const resEl = document.createElement('div');
    resEl.className   = 'term-result' + (res && !res.ok ? ' term-err' : '');
    resEl.textContent = (res && res.output) || (res ? '(no output)' : 'Error: no response');
    out.appendChild(resEl);

    // Keep last 500 lines
    while (out.children.length > 500) out.removeChild(out.firstChild);
    out.scrollTop = out.scrollHeight;
}

registerTab('terminal', {
    onActivate: buildTerminal,
});

window.termRun      = termRun;
window.termClear    = termClear;
window.termQuick    = termQuick;
window.termHistNav  = termHistNav;
