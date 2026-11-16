/* app.js — Core: tab router, SSE, API, toast, matrix rain */
'use strict';

// ── Matrix Rain ──────────────────────────────────────────────────────
(function () {
    const canvas = document.getElementById('matrix-rain');
    const ctx    = canvas.getContext('2d');
    const CHARS  = 'PWRLVL9000アイウエオカキクケコサシスセソタチツ01ABCDEFabcdef!@#$%^&*<>';
    let cols, drops;

    function resize() {
        canvas.width  = window.innerWidth;
        canvas.height = window.innerHeight;
        cols  = Math.floor(canvas.width / 14);
        drops = Array(cols).fill(1);
    }

    function draw() {
        ctx.fillStyle = 'rgba(6,6,6,0.05)';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = '#00ff41';
        ctx.font      = '14px monospace';
        for (let i = 0; i < cols; i++) {
            const ch = CHARS[Math.floor(Math.random() * CHARS.length)];
            ctx.fillText(ch, i * 14, drops[i] * 14);
            if (drops[i] * 14 > canvas.height && Math.random() > 0.975) {
                drops[i] = 0;
            }
            drops[i]++;
        }
    }

    resize();
    window.addEventListener('resize', resize);
    setInterval(draw, 50);
})();

// ── Tab Router ───────────────────────────────────────────────────────
const _tabs = {};
var   _activeTab = 'wifi';  // var so other scripts can read window._activeTab

function registerTab(name, opts) {
    _tabs[name] = opts;
}

document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });
    switchTab('wifi');
    startSSE();
    statusPoll();
});

function switchTab(name) {
    if (_activeTab && _tabs[_activeTab] && _tabs[_activeTab].onDeactivate) {
        _tabs[_activeTab].onDeactivate();
    }
    document.querySelectorAll('.tab-btn').forEach(b => {
        b.classList.toggle('active', b.dataset.tab === name);
    });
    document.querySelectorAll('.tab-panel').forEach(p => {
        p.classList.toggle('active', p.id === 'tab-' + name);
    });
    _activeTab = name;
    if (_tabs[name] && _tabs[name].onActivate) {
        _tabs[name].onActivate();
    }
}

window.switchTab = switchTab;

// ── API Helper ───────────────────────────────────────────────────────
async function api(endpoint, opts) {
    try {
        const resp = await fetch(endpoint, {
            headers: { 'Content-Type': 'application/json' },
            ...opts,
        });
        return await resp.json();
    } catch (e) {
        return null;
    }
}

window.api = api;

// ── SSE Event Stream ──────────────────────────────────────────────────
const LOG_COLORS = {
    INFO:    'ev-info',
    WARN:    'ev-warn',
    ERROR:   'ev-error',
    ATTACK:  'ev-attack',
    CRACK:   'ev-crack',
    SCAN:    'ev-scan',
    WEBSCAN: 'ev-webscan',
    NETSCAN: 'ev-netscan',
    SHELL:   'ev-shell',
    XP:      'ev-xp',
};

let _es = null;

function startSSE() {
    const log = document.getElementById('event-log');
    if (_es) { _es.close(); }
    _es = new EventSource('/events');

    _es.onmessage = ev => {
        try {
            const data = JSON.parse(ev.data);
            appendEvent(log, data);
            window._xpFlash && window._xpFlash(data);
        } catch (e) { /* ignore SSE keepalive comment lines */ }
    };

    _es.onerror = () => {
        // Browser auto-reconnects on error; nothing to do.
    };

    window.addEventListener('beforeunload', () => { if (_es) _es.close(); }, { once: true });
}

function appendEvent(log, ev) {
    const cls   = LOG_COLORS[ev.level] || 'ev-info';
    const t     = new Date(ev.ts * 1000).toLocaleTimeString();
    const el    = document.createElement('div');
    el.className = 'ev ' + cls;
    el.textContent = `[${t}] [${ev.level}] ${ev.msg}`;
    log.appendChild(el);
    // Keep last 300 entries
    while (log.children.length > 300) {
        log.removeChild(log.firstChild);
    }
    log.scrollTop = log.scrollHeight;
}

// ── Status Polling ────────────────────────────────────────────────────
let _status = {};

async function statusPoll() {
    const s = await api('/api/status');
    if (s) {
        _status = s;
        const hdr = document.getElementById('hdr-status');
        if (hdr) {
            if (s.wifi_attacking) {
                hdr.textContent = 'ATTACKING';
                hdr.style.color = '#ff2020';
            } else if (s.wifi_scanning || s.web_scanning || s.net_scanning) {
                hdr.textContent = 'SCANNING';
                hdr.style.color = '#ffcc00';
            } else {
                hdr.textContent = 'STANDBY';
                hdr.style.color = '#00ff41';
            }
        }
        // Update XP / level display
        if (s.level !== undefined) updateXPBar(s);
        // Notify active tab
        if (_tabs[_activeTab] && _tabs[_activeTab].onStatus) {
            _tabs[_activeTab].onStatus(s);
        }
    }
    setTimeout(statusPoll, 3000);
}

// ── XP / Level Bar ────────────────────────────────────────────────────
const XP_THRESHOLDS = [0, 100, 300, 700, 1500, 3000, 6000, 12000, 25000];

function updateXPBar(s) {
    const lvlEl   = document.getElementById('xp-level');
    const titleEl = document.getElementById('xp-title');
    const barEl   = document.getElementById('xp-bar');
    const numEl   = document.getElementById('xp-numbers');
    const sprEl   = document.getElementById('necro-sprite');
    if (!lvlEl) return;

    const xp      = s.xp    || 0;
    const level   = s.level || 1;
    const title   = s.title || 'APPRENTICE';
    const xpNext  = s.xp_next;

    lvlEl.textContent   = `LVL ${level}`;
    titleEl.textContent = title;

    // XP bar fill
    let pct = 0;
    if (xpNext) {
        const prevThresh = XP_THRESHOLDS[level - 1] || 0;
        pct = Math.min(100, ((xp - prevThresh) / (xpNext - prevThresh)) * 100);
        numEl.textContent = `${xp} / ${xpNext} XP`;
    } else {
        pct = 100;
        numEl.textContent = `${xp} XP  ★ MAX ★`;
    }
    if (barEl) barEl.style.width = pct + '%';

    // Sprite: swap to attack animation during attack, cast during scan
    if (sprEl) {
        if (s.wifi_attacking) {
            sprEl.className = 'necro-sprite necro-attack';
        } else if (s.wifi_scanning || s.web_scanning || s.net_scanning) {
            sprEl.className = 'necro-sprite necro-cast';
        } else {
            sprEl.className = 'necro-sprite necro-idle';
        }
    }
}

// SSE: flash on level-up
const _origAppendEvent = window.appendEvent;
window._xpFlash = function(ev) {
    if (ev.level === 'XP' && ev.data && ev.data.level_up) {
        const bar = document.getElementById('char-bar');
        if (bar) {
            bar.classList.add('level-up-flash');
            setTimeout(() => bar.classList.remove('level-up-flash'), 1200);
        }
    }
};

window.getStatus  = () => _status;
window.statusPoll = statusPoll;

// ── HTML Escape Helper ────────────────────────────────────────────────
function esc(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

window.esc = esc;

// ── Toast ─────────────────────────────────────────────────────────────
function toast(msg, type = 'info', duration = 3000) {
    const c  = document.getElementById('toast-container');
    const el = document.createElement('div');
    el.className = `toast toast-${type}`;
    el.textContent = msg;
    c.appendChild(el);
    setTimeout(() => {
        el.style.opacity = '0';
        el.style.transition = 'opacity 0.3s';
        setTimeout(() => el.remove(), 300);
    }, duration);
}

window.toast = toast;
