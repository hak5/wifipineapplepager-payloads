// PagerMesh web console
// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const $ = (id) => document.getElementById(id);
let S = null;            // last state from the Pager
let ver = -1;
let map = null, tiles = null, meLayer = null, wpLayer = null, trailLayer = null;
const markers = {};      // node id -> marker
let tab = "nodes";
let fitted = false;
let destKeep = "all:0";

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

async function api(path, body) {
  const opt = body === undefined ? {} : {
    method: "POST", headers: { "Content-Type": "application/json", "X-PagerMesh": "1" }, body: JSON.stringify(body),
  };
  const r = await fetch(path, opt);
  if (r.status === 401 && path !== "/api/login") { showLogin(); throw new Error("login"); }
  return r;
}

function showLogin() { $("app").classList.add("hidden"); $("login").classList.remove("hidden"); $("pw").focus(); }
function showApp() { $("login").classList.add("hidden"); $("app").classList.remove("hidden"); initMap(); }

$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("login-err").textContent = "";
  const r = await api("/api/login", { password: $("pw").value });
  if (r.ok) { $("pw").value = ""; showApp(); poll(true); }
  else { const j = await r.json().catch(() => ({})); $("login-err").textContent = j.error || "Sign in failed"; }
});

$("b-out").onclick = async () => { await api("/api/logout", {}); location.reload(); };
$("b-pos").onclick = async () => {
  const r = await api("/api/position", {});
  const j = await r.json().catch(() => ({}));
  flash(j.message || (r.ok ? "Position sent" : "Not sent"), !r.ok);
};

for (const b of document.querySelectorAll(".tab")) {
  b.onclick = () => {
    tab = b.dataset.tab;
    for (const x of document.querySelectorAll(".tab")) x.classList.toggle("on", x === b);
    $("t-nodes").classList.toggle("hidden", tab !== "nodes");
    $("t-chat").classList.toggle("hidden", tab !== "chat");
    $("t-settings").classList.toggle("hidden", tab !== "settings");
    $("t-sigint").classList.toggle("hidden", tab !== "sigint");
    if (tab === "settings") { loadSetup(); if (!S || !S.setup) loadRadio(); }
    if (tab === "sigint") loadSigint();
    if (tab === "chat") { drawChat(); markRead(); scrollChat(); }
    if (map) setTimeout(() => map.invalidateSize(), 50);
  };
}

function flash(msg, bad) {
  const n = $("send-note");
  n.textContent = msg; n.style.color = bad ? "var(--bad)" : "var(--dim)";
  if (tab !== "chat") { $("b-pos").title = msg; }
  clearTimeout(flash.t); flash.t = setTimeout(() => { n.textContent = ""; }, 5000);
}

// ---- formatting
function fmtRange(m) { if (m == null) return "-"; return m >= 1000 ? (m / 1000).toFixed(1) + " km" : m + " m"; }
const DIRS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
function fmtDir(b) { return b == null ? "" : " " + DIRS[Math.floor(((b + 22.5) % 360) / 45)]; }
function fmtAge(s) {
  if (s == null) return "-";
  if (s < 60) return s + "s"; if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h"; return Math.floor(s / 86400) + "d";
}
function fmtBatt(b) { if (b == null) return "-"; return b > 100 ? "PWR" : b + "%"; }
function nodeName(n) { return n.short || n.long || n.id.slice(-4); }
function hhmm(t) { const d = new Date(t * 1000); return d.toTimeString().slice(0, 5); }

// ---- map
async function initMap() {
  if (map) return;
  map = L.map("map", { zoomControl: true, attributionControl: true }).setView([39.5, -98.35], 4);
  meLayer = L.layerGroup().addTo(map);
  wpLayer = L.layerGroup().addTo(map);
  trailLayer = L.layerGroup().addTo(map);
  map.on("click", mapMenu);
  try {
    const r = await api("/api/sources");
    const j = await r.json();
    const sel = $("src");
    sel.innerHTML = "";
    for (const s of j.sources) {
      const o = document.createElement("option"); o.value = s.slug; o.textContent = s.name; sel.appendChild(o);
    }
    const def = j.sources.find((s) => s.name === j.default) || j.sources[0];
    if (def) { sel.value = def.slug; setSource(def); }
    sel.onchange = () => setSource(j.sources.find((s) => s.slug === sel.value));
  } catch (e) { /* no basemaps: nodes still show */ }
}

function setSource(s) {
  if (!s) return;
  if (tiles) map.removeLayer(tiles);
  tiles = L.tileLayer("/tiles/" + s.slug + "/{z}/{x}/{y}.png", {
    minZoom: Math.max(3, s.minz), maxZoom: Math.min(18, s.maxz), attribution: esc(s.name),
  }).addTo(map);
}

function drawMap() {
  if (!map || !S) return;
  const seen = {};
  const pts = [];
  for (const n of S.nodes) {
    if (n.me || n.lat == null) continue;
    seen[n.id] = 1;
    const old = n.age_s != null && n.age_s > 1800;
    const ico = L.divIcon({ className: "", html: '<div class="node-ico' + (old ? " old" : "") + '"></div>', iconSize: [14, 14] });
    const tip = esc(nodeName(n));
    const pop = "<b>" + esc(n.long || n.short || n.id) + "</b><br>" + esc(n.id) +
      "<br>Range " + esc(fmtRange(n.range_m) + fmtDir(n.bearing)) + "<br>Battery " + esc(fmtBatt(n.battery)) +
      " &middot; SNR " + esc(n.snr == null ? "-" : n.snr) + " &middot; hops " + esc(n.hops == null ? "-" : n.hops) +
      "<br>Heard " + esc(fmtAge(n.age_s)) + " ago";
    let m = markers[n.id];
    if (!m) {
      m = L.marker([n.lat, n.lon], { icon: ico }).addTo(map);
      m.bindTooltip(tip, { permanent: true, direction: "right", offset: [8, 0], className: "lbl" });
      m.bindPopup(pop);
      markers[n.id] = m;
    } else {
      m.setLatLng([n.lat, n.lon]); m.setIcon(ico); m.setPopupContent(pop);
    }
    pts.push([n.lat, n.lon]);
  }
  for (const id of Object.keys(markers)) if (!seen[id]) { map.removeLayer(markers[id]); delete markers[id]; }
  meLayer.clearLayers();
  const mp = manualPos();
  if (S.gps && S.gps.fix) {
    L.marker([S.gps.lat, S.gps.lon], { icon: L.divIcon({ className: "", html: '<div class="me-ico"></div>', iconSize: [16, 16] }) })
      .bindTooltip("Pager", { permanent: true, direction: "right", offset: [9, 0], className: "lbl" }).addTo(meLayer);
    pts.push([S.gps.lat, S.gps.lon]);
  } else if (mp) {
    L.marker(mp, { icon: L.divIcon({ className: "", html: '<div class="me-ico"></div>', iconSize: [16, 16] }) })
      .bindTooltip("Pager (set on map)", { permanent: true, direction: "right", offset: [9, 0], className: "lbl" }).addTo(meLayer);
    pts.push(mp);
  }
  drawWaypoints();
  if (!fitted && pts.length) {
    fitted = true;
    if (pts.length === 1) map.setView(pts[0], 13); else map.fitBounds(pts, { padding: [40, 40], maxZoom: 14 });
  }
}

// ---- nodes table
function hideAge() { return Number((S.cfg || {}).hide_age || 0); }
function visible(n) { const h = hideAge(); return n.me || !h || (n.age_s != null && n.age_s <= h); }
function drawNodes() {
  const tb = $("node-rows");
  tb.innerHTML = "";
  const others = S.nodes.filter((n) => !n.me);
  const shown = others.filter(visible);
  $("no-nodes").classList.toggle("hidden", others.length > 0);
  $("node-count").textContent = shown.length === others.length ? others.length + " nodes" : shown.length + " of " + others.length + " nodes";
  const ha = $("hide-age"); if (document.activeElement !== ha) ha.value = String(hideAge());
  if (detailId) drawDetail();
  for (const n of S.nodes) {
    if (!visible(n)) continue;
    const tr = document.createElement("tr");
    if (n.me) tr.className = "me";
    else if (n.age_s != null && n.age_s > 1800) tr.className = "old";
    const tags = (n.fav ? '<span class="tag fav">&#9733;</span>' : "") + (n.mqtt ? '<span class="tag">MQTT</span>' : "");
    tr.innerHTML = '<td><span class="name">' + esc(nodeName(n)) + (n.me ? " (Pager)" : "") + "</span>" + tags + '<span class="long">' +
      esc(n.long || n.id) + "</span></td><td>" + esc(n.me ? "-" : fmtRange(n.range_m) + fmtDir(n.bearing)) + "</td><td>" +
      esc(fmtBatt(n.battery)) + "</td><td>" + esc(n.snr == null || n.me ? "-" : n.snr) + "</td><td>" +
      esc(n.hops == null || n.me ? "-" : n.hops) + "</td><td>" + esc(n.me ? "-" : fmtAge(n.age_s)) + "</td>";
    tr.onclick = () => {
      if (n.lat != null && map) { map.setView([n.lat, n.lon], Math.max(map.getZoom(), 13)); const m = markers[n.id]; if (m) m.openPopup(); }
      if (!n.me) openDetail(n.id);
    };
    if (!n.me) tr.ondblclick = () => { curConv = "dm:" + n.id; document.querySelector('[data-tab="chat"]').click(); };
    tb.appendChild(tr);
  }
}

// ---- chat: a list of conversations (one per DM contact, one per channel) and a thread view
let curConv = "";          // open conversation ("" = the list)
function convOf(dest) { const [k, v] = dest.split(":"); return k === "dm" ? "dm:" + v : "ch:" + (Number(v) || 0); }
function destOf(conv) { return conv.startsWith("dm:") ? "dm:" + conv.slice(3) : "all:" + conv.slice(3); }
function convTitle(conv) {
  const c = (S.convs || []).find((x) => x.conv === conv);
  if (c) return c.title;
  if (conv.startsWith("ch:")) { const ch = S.channels.find((x) => "ch:" + x.index === conv); return ch ? ch.name : conv.slice(3); }
  const n = S.nodes.find((x) => "dm:" + x.id === conv);
  return "DM " + (n ? nodeName(n) : conv.slice(3));
}

function drawDest() {
  const sel = $("dest");
  const cur = sel.value || destKeep;
  sel.innerHTML = "";
  for (const c of S.channels) {
    const o = document.createElement("option"); o.value = "all:" + c.index; o.textContent = "Channel: " + c.name; sel.appendChild(o);
  }
  for (const n of S.nodes) {
    if (n.me) continue;
    const o = document.createElement("option"); o.value = "dm:" + n.id;
    o.textContent = "Direct: " + nodeName(n) + (n.long && n.long !== n.short ? " (" + n.long + ")" : "");
    sel.appendChild(o);
  }
  if ([...sel.options].some((o) => o.value === cur)) sel.value = cur;
  destKeep = sel.value;
}
$("dest").onchange = () => { destKeep = $("dest").value; };
$("b-open").onclick = () => { if ($("dest").value) openConv(convOf($("dest").value)); };
$("b-back").onclick = () => { curConv = ""; drawChat(); };

function openConv(conv) {
  curConv = conv;
  drawChat();
  scrollChat();
  markRead();
  $("text").focus();
}

function drawConvs() {
  const box = $("convs");
  box.innerHTML = "";
  const last = {};
  for (const c of S.chat) last[c.conv] = c;
  for (const v of S.convs || []) {
    const m = last[v.conv];
    const d = document.createElement("div");
    d.className = "conv" + (v.unread ? " new" : "");
    const prev = m ? (m.dir === "out" ? "me: " : (m.direct ? "" : (m.from || m.from_id) + ": ")) + m.text : "";
    d.innerHTML = '<div class="ct"><b>' + esc(v.title) + "</b><small>" + esc(prev) + "</small></div>" +
      '<span class="when">' + esc(dayTime(v.last)) + "</span>" +
      (v.unread ? '<span class="badge">' + v.unread + "</span>" : "");
    d.onclick = () => openConv(v.conv);
    box.appendChild(d);
  }
  if (!(S.convs || []).length) box.innerHTML = '<div class="empty">No chats in the last 7 days. Pick a channel or a node above and press Open.</div>';
  $("b-delall").disabled = !(S.convs || []).length;
}

function drawChat() {
  $("v-list").classList.toggle("hidden", !!curConv);
  $("v-thread").classList.toggle("hidden", !curConv);
  if (!curConv) { drawConvs(); return; }
  $("th-title").textContent = convTitle(curConv);
  const box = $("msgs");
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
  box.innerHTML = "";
  const rows = S.chat.filter((c) => c.conv === curConv);
  for (const c of rows) {
    const d = document.createElement("div");
    d.className = "msg" + (c.dir === "out" ? " out" : "");
    const who = c.dir === "out" ? "me" : (c.from || c.from_id);
    let st = "";
    if (c.dir === "out" && c.status) {
      const cls = c.status === "delivered" ? "ok" : c.status === "failed" ? "bad" : "";
      st = '<span class="st ' + cls + '">' + esc(c.status === "delivered" ? "✓✓ delivered" : c.status) + "</span>";
    }
    d.innerHTML = '<button class="del" type="button" title="Delete this message">&times;</button>' +
      '<div class="meta">' + esc(dayTime(c.t)) + " " + esc(who) + st + "</div>" + esc(c.text);
    d.querySelector(".del").onclick = () => del("msg", c.mid);
    box.appendChild(d);
  }
  if (!rows.length) box.innerHTML = '<div class="empty">No messages yet. Type below to start.</div>';
  if (atBottom) scrollChat();
  const q = $("quick");
  if (!q.dataset.done && S.quick.length) {
    q.dataset.done = "1";
    for (const m of S.quick) {
      const b = document.createElement("button"); b.className = "btn small"; b.type = "button"; b.textContent = m;
      b.onclick = () => send(m); q.appendChild(b);
    }
  }
}
function scrollChat() { const b = $("msgs"); b.scrollTop = b.scrollHeight; }
function dayTime(t) {
  const d = new Date(t * 1000), n = new Date();
  if (d.toDateString() === n.toDateString()) return hhmm(t);
  return d.toLocaleDateString([], { month: "short", day: "numeric" }) + " " + hhmm(t);
}

async function del(what, id) {
  if (what === "all" && !confirm("Delete ALL chats? This also deletes the chat logs in /root/loot/PagerMesh and cannot be undone.")) return;
  const r = await api("/api/delete", { what, id: id || "" });
  const j = await r.json().catch(() => ({}));
  flash(j.message || (r.ok ? "Deleted" : "Not deleted"), !r.ok);
  if (r.ok && what !== "msg") curConv = "";
  poll(true);
}
$("b-delconv").onclick = () => del("conv", curConv);
$("b-delall").onclick = () => del("all");

async function send(text) {
  text = text.trim();
  if (!text || !curConv) return;
  const [kind, val] = destOf(curConv).split(":");
  const body = kind === "dm" ? { text, to: val } : { text, to: "all", channel: Number(val) || 0 };
  const r = await api("/api/chat", body);
  const j = await r.json().catch(() => ({}));
  if (r.ok) { $("text").value = ""; flash("Sent"); poll(true); setTimeout(scrollChat, 300); } else flash(j.message || "Not sent", true);
}
$("compose").addEventListener("submit", (e) => { e.preventDefault(); send($("text").value); });

async function markRead() {
  if (!S || !curConv) return;
  const v = (S.convs || []).find((x) => x.conv === curConv);
  if (v && v.unread) await api("/api/read", { conv: curConv });
}

// ---- helpers for the 1.0 features
async function post(path, body) {
  const r = await api(path, body);
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok && j.ok !== false, j };
}
function note(id, msg, bad) { const n = $(id); n.textContent = msg || ""; n.style.color = bad ? "var(--bad)" : "var(--acc)"; }
function toast(msg) {
  let t = $("toast");
  if (!t) { t = document.createElement("div"); t.id = "toast"; t.className = "toast"; document.body.appendChild(t); }
  t.textContent = msg; t.classList.remove("hidden");
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.add("hidden"), 6000);
}
let lastNote = Math.floor(Date.now() / 1000) - 5;
function showNotes() {
  for (const n of S.notes || []) if (n.t > lastNote) { lastNote = n.t; toast(n.msg); }
}
function manualPos() {
  const v = (S && S.cfg && S.cfg.manual_pos) || "";
  const p = v.split(",").map(Number);
  return p.length === 2 && !isNaN(p[0]) && !isNaN(p[1]) ? p : null;
}
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function btn(label, fn, cls) { const b = el("button", "btn small" + (cls ? " " + cls : ""), label); b.type = "button"; b.onclick = fn; return b; }

// ---- node details (Nodes tab): hardware, role, position age, MQTT, favorite, traceroute, request position
let detailId = "";
let detailInfo = null;
async function openDetail(id) {
  detailId = id;
  detailInfo = null;
  drawDetail();
  await refreshDetail();
}
async function refreshDetail() {
  if (!detailId) return;
  try { const r = await api("/api/node?id=" + encodeURIComponent(detailId)); if (r.ok) detailInfo = await r.json(); } catch (e) { /* keep */ }
  drawDetail();
}
function drawDetail() {
  const box = $("node-detail");
  const n = S && S.nodes.find((x) => x.id === detailId);
  box.classList.toggle("hidden", !n);
  if (!n) return;
  box.innerHTML = "";
  const head = el("div", "row");
  head.appendChild(el("h3", "", (n.long || n.short || n.id)));
  if (n.fav) head.appendChild(el("span", "tag fav", "★ favorite"));
  if (n.mqtt) head.appendChild(el("span", "tag", "via MQTT"));
  const sp = el("span"); sp.style.flex = "1"; head.appendChild(sp);
  head.appendChild(btn("Close", () => { detailId = ""; drawDetail(); }));
  box.appendChild(head);
  const kv = el("div", "kv");
  const d = detailInfo || {};
  const rows = [["ID", n.id + (n.short ? "  (" + n.short + ")" : "")], ["Hardware", n.hw || "-"], ["Role", n.role || "-"],
    ["Last heard", fmtAge(n.age_s) + " ago"], ["Range", fmtRange(n.range_m) + fmtDir(n.bearing)],
    ["Position", n.lat == null ? "none" : n.lat.toFixed(5) + ", " + n.lon.toFixed(5) + (n.pos_age != null ? " (" + fmtAge(n.pos_age) + " old)" : "")],
    ["Battery", fmtBatt(n.battery) + (n.voltage ? " · " + n.voltage + " V" : "")], ["SNR / hops", (n.snr == null ? "-" : n.snr + " dB") + " · " + (n.hops == null ? "-" : n.hops + " hops")],
    ["Channel util.", n.ch_util == null ? "-" : n.ch_util + " % (air TX " + (n.air_tx == null ? "-" : n.air_tx) + " %)"],
    ["Heard here", (d.packets || 0) + " packets, RSSI " + (d.rssi == null ? "-" : d.rssi + " dBm") + (d.rssi_avg == null ? "" : " (avg " + d.rssi_avg + ")")]];
  for (const [k, v] of rows) { kv.appendChild(el("span", "", k)); kv.appendChild(el("span", "", v)); }
  box.appendChild(kv);
  if (d.trace) box.appendChild(el("div", "trace", "Traceroute: " + d.trace));
  const acts = el("div", "row");
  acts.style.flexWrap = "wrap";
  acts.appendChild(btn("Message", () => { curConv = "dm:" + n.id; document.querySelector('[data-tab="chat"]').click(); }));
  acts.appendChild(btn("Traceroute", () => nodeAct("trace")));
  acts.appendChild(btn("Request position", () => nodeAct("reqpos")));
  acts.appendChild(btn(n.fav ? "Unfavorite" : "Favorite", () => nodeAct(n.fav ? "unfav" : "fav")));
  if (n.lat != null) acts.appendChild(btn("Center map", () => map && map.setView([n.lat, n.lon], Math.max(map.getZoom(), 14))));
  box.appendChild(acts);
}
async function nodeAct(action) {
  const { ok, j } = await post("/api/node", { id: detailId, action });
  flash(j.message || (ok ? "Sent" : "Not sent"), !ok);
  toast(j.message || "");
  if (action === "trace" && ok) {
    for (let i = 0; i < 30 && detailId; i++) {
      await new Promise((r) => setTimeout(r, 3000));
      await refreshDetail();
      if (detailInfo && detailInfo.trace_done) break;
    }
  } else { setTimeout(refreshDetail, 800); }
}
$("hide-age").onchange = async () => {
  const { ok } = await post("/api/cfg", { hide_age: $("hide-age").value });
  if (ok) poll(true);
};

// ---- map: click menu (set the Pager's location, drop a waypoint), waypoints, trails
function mapMenu(e) {
  const box = el("div", "map-menu");
  L.DomEvent.disableClickPropagation(box);       // buttons that rebuild the menu must not reach the map
  const ll = e.latlng;
  box.appendChild(el("div", "hint", ll.lat.toFixed(5) + ", " + ll.lng.toFixed(5)));
  box.appendChild(btn("Set the Pager's location here", async () => {
    const { ok, j } = await post("/api/cfg", { manual_pos: ll.lat.toFixed(6) + "," + ll.lng.toFixed(6) });
    toast(ok ? "Pager location set here (used while there is no GPS fix)" : j.message || "Not saved");
    map.closePopup(); poll(true);
  }, "primary"));
  box.appendChild(btn("Drop a waypoint here", () => setTimeout(() => {   // after the click: Leaflet looks at the clicked button
    box.innerHTML = "";
    const nm = el("input"); nm.placeholder = "Name (max 30)"; nm.maxLength = 30;
    const ds = el("input"); ds.placeholder = "Description (optional)"; ds.maxLength = 100;
    const hrs = el("select", "inline");
    for (const [v, t] of [["6", "expires in 6 h"], ["24", "expires in 24 h"], ["72", "expires in 3 days"], ["0", "never expires"]]) {
      const o = el("option", "", t); o.value = v; hrs.appendChild(o);
    }
    hrs.value = "24";
    box.appendChild(nm); box.appendChild(ds); box.appendChild(hrs);
    box.appendChild(btn("Send to the mesh", async () => {
      const { ok, j } = await post("/api/waypoint", { lat: ll.lat, lon: ll.lng, name: nm.value, desc: ds.value, hours: Number(hrs.value) });
      toast(j.message || (ok ? "Waypoint sent" : "Not sent")); map.closePopup(); poll(true);
    }, "primary"));
    setTimeout(() => nm.focus(), 50);
  }, 0)));
  if (manualPos()) box.appendChild(btn("Clear the map-set location", clearManual));
  L.popup().setLatLng(ll).setContent(box).openOn(map);
}
async function clearManual() {
  const { ok } = await post("/api/cfg", { manual_pos: "" });
  toast(ok ? "Map-set location cleared" : "Not saved");
  if (map) map.closePopup();
  poll(true);
}
const wpMarkers = {};
function drawWaypoints() {
  if (!wpLayer) return;
  const seen = {};
  for (const w of S.waypoints || []) {
    seen[w.id] = 1;
    const box = el("div", "map-menu");
    L.DomEvent.disableClickPropagation(box);
    box.appendChild(el("b", "", w.name));
    if (w.description) box.appendChild(el("div", "", w.description));
    box.appendChild(el("div", "hint", (w.owner ? "from " + w.owner + " · " : "") +
      (w.expire ? "expires " + new Date(w.expire * 1000).toLocaleString() : "no expiry")));
    box.appendChild(btn("Delete", async () => {
      const { ok, j } = await post("/api/waypoint", { delete: w.id });
      toast(j.message || (ok ? "Deleted" : "Not deleted")); map.closePopup(); poll(true);
    }, "danger"));
    let m = wpMarkers[w.id];
    if (!m) {
      m = L.marker([w.lat, w.lon], { icon: L.divIcon({ className: "", html: '<div class="wp-ico"></div>', iconSize: [12, 12] }) }).addTo(wpLayer);
      m.bindTooltip(w.name, { permanent: true, direction: "right", offset: [8, 0], className: "lbl" });
      wpMarkers[w.id] = m;
    } else m.setLatLng([w.lat, w.lon]);
    m.bindPopup(box);
  }
  for (const id of Object.keys(wpMarkers)) if (!seen[id]) { wpLayer.removeLayer(wpMarkers[id]); delete wpMarkers[id]; }
}
function drawTrails(trails) {
  if (!trailLayer) return;
  trailLayer.clearLayers();
  if (!$("sig-trails").checked) return;
  for (const id of Object.keys(trails || {})) {
    const pts = trails[id].map((p) => [p[1], p[2]]);
    if (pts.length > 1) L.polyline(pts, { color: "#67ea94", weight: 2, opacity: 0.7, dashArray: "4 4" }).addTo(trailLayer);
  }
}

// ---- SIGINT tab
let sigTimer = null;
let scanPresetsDrawn = false;
async function loadSigint() {
  clearTimeout(sigTimer);
  if (tab !== "sigint" && !$("sig-trails").checked) return;
  try {
    const r = await api("/api/sigint");
    if (r.ok) drawSigint(await r.json());
  } catch (e) { /* offline */ }
  sigTimer = setTimeout(loadSigint, 5000);
}
function drawSigint(j) {
  const st = j.stats;
  $("sig-total").textContent = st.total + " packets since " + new Date(st.since * 1000).toTimeString().slice(0, 5) +
    " · " + (st.per_min[st.per_min.length - 1] || 0) + " in the last minute";
  const sp = $("sig-spark"); sp.innerHTML = "";
  const mx = Math.max(1, ...st.per_min);
  for (const v of st.per_min) { const i = el("i"); i.style.height = Math.round((v / mx) * 100) + "%"; i.title = v + "/min"; sp.appendChild(i); }
  const pc = $("sig-ports"); pc.innerHTML = "";
  for (const [p, c] of st.ports) pc.appendChild(el("span", "chip", p + " " + c));
  const tb = $("sig-nodes"); tb.innerHTML = "";
  for (const n of st.nodes) {
    const tr = el("tr");
    for (const v of [n.name, n.packets, n.rssi == null ? "-" : n.rssi, n.rssi_avg == null ? "-" : n.rssi_avg, n.snr == null ? "-" : n.snr, n.enc || ""]) tr.appendChild(el("td", "", String(v)));
    tr.title = (n.top || []).map((x) => x[0] + " " + x[1]).join(", ") + (n.mqtt ? " · " + n.mqtt + " via MQTT" : "");
    tb.appendChild(tr);
  }
  const pk = $("sig-pkts"); pk.innerHTML = "";
  for (const p of j.packets.slice().reverse()) {
    const ln = el("div", p.port === "ENCRYPTED" ? "enc" : "", new Date(p.t * 1000).toTimeString().slice(0, 8) + " " +
      nameOfNum(p.from) + " > " + (p.to === 4294967295 ? "all" : nameOfNum(p.to)) + " ch" + p.ch + " " + p.port + " " + p.size + "B" +
      (p.rssi == null ? "" : " " + p.rssi + "dBm") + (p.snr == null ? "" : " " + p.snr + "dB") + (p.hops == null ? "" : " h" + p.hops) +
      (p.mqtt ? " mqtt" : "") + (p.pki ? " pki" : ""));
    pk.appendChild(ln);
  }
  drawTrails(j.trails);
  if (!scanPresetsDrawn && j.presets) {
    scanPresetsDrawn = true;
    const box = $("scan-presets");
    for (const [num, name] of j.presets) {
      const lab = el("label", "chip"); const cb = el("input"); cb.type = "checkbox"; cb.value = num; cb.checked = true;
      lab.appendChild(cb); lab.appendChild(document.createTextNode(name)); box.appendChild(lab);
    }
  }
  const sc = j.scan || {};
  $("scan-start").disabled = !!sc.running;
  $("scan-stop").disabled = !sc.running;
  $("scan-status").textContent = sc.running ? "Scanning: " + (sc.now || "") + " (" + (sc.results || []).length + " of " + (sc.presets || []).length + " done)" :
    (sc.results && sc.results.length ? "Last scan - the radio went back to " + (sc.orig || "its own preset") + "." : "");
  const rt = $("scan-results"); rt.innerHTML = "";
  for (const x of sc.results || []) {
    const tr = el("tr");
    tr.appendChild(el("td", "", x.preset));
    tr.appendChild(el("td", "", x.error ? x.error : x.packets + " packets, " + x.nodes + " nodes" + (x.encrypted ? ", " + x.encrypted + " encrypted" : "") +
      (x.best_rssi == null ? "" : ", best " + x.best_rssi + " dBm")));
    rt.appendChild(tr);
  }
}
function nameOfNum(num) {
  const id = "!" + (num >>> 0).toString(16).padStart(8, "0");
  const n = S && S.nodes.find((x) => x.id === id);
  return n ? nodeName(n) : id;
}
$("sig-trails").onchange = () => loadSigint();
$("scan-start").onclick = async () => {
  const presets = [...document.querySelectorAll("#scan-presets input:checked")].map((x) => Number(x.value));
  if (!presets.length) { toast("Pick at least one preset"); return; }
  const dwell = Number($("scan-dwell").value);
  const mins = Math.ceil((presets.length * (dwell + 20)) / 60);
  if (!confirm("Scan " + presets.length + " presets (about " + mins + " min)? The radio restarts for each preset and you are off your mesh until it goes back to its own settings.")) return;
  const { ok, j } = await post("/api/scan", { presets, dwell });
  toast(j.message || (ok ? "Scan started" : "Not started")); loadSigint();
};
$("scan-stop").onclick = async () => { const { j } = await post("/api/scan", { stop: true }); toast(j.message || ""); loadSigint(); };

// ---- Settings: radio settings, owner name, channels, share QR
let R = null;               // last /api/radio
async function loadRadio() {
  try { const r = await api("/api/radio"); if (r.ok) R = await r.json(); } catch (e) { return; }
  drawRadio(); drawChannels(); drawApp(); drawTakForm();
}
function drawRadio() {
  if (!R) return;
  $("radio-hw").textContent = [R.metadata.hw, R.metadata.firmware && "fw " + R.metadata.firmware].filter(Boolean).join(" · ");
  if (document.activeElement !== $("own-long")) $("own-long").value = R.owner.long || "";
  if (document.activeElement !== $("own-short")) $("own-short").value = R.owner.short || "";
  const box = $("radio-fields"); box.innerHTML = "";
  if (!Object.keys(R.values).length) { box.appendChild(el("div", "hint", "The radio has not sent its settings yet (not connected?).")); return; }
  let group = "";
  for (const d of R.settings) {
    if (!(d.key in R.values)) continue;
    if (d.group !== group) { group = d.group; box.appendChild(el("h3", "", group)); }
    const row = el("label", "field");
    row.appendChild(el("span", d.risky ? "risky" : "", d.label + (d.risky ? " *" : "")));
    let inp;
    const v = R.values[d.key];
    if (d.type === "bool") { inp = el("input"); inp.type = "checkbox"; inp.checked = !!v; }
    else if (d.type === "enum") {
      inp = el("select");
      for (const [num, name] of d.choices) { const o = el("option", "", name); o.value = num; inp.appendChild(o); }
      inp.value = String(v);
    } else if (d.type === "secret") { inp = el("input"); inp.type = "password"; inp.autocomplete = "new-password"; inp.placeholder = v ? "set - leave empty to keep" : "not set"; }
    else { inp = el("input"); if (d.type !== "str") { inp.type = "number"; if (d.min != null) inp.min = d.min; if (d.max != null) inp.max = d.max; } else if (d.max) inp.maxLength = d.max; inp.value = v; }
    inp.dataset.key = d.key; inp.dataset.type = d.type; inp.dataset.risky = d.risky ? "1" : "";
    row.appendChild(inp);
    box.appendChild(row);
  }
  box.appendChild(el("div", "hint", "* asks first: region, preset and Wi-Fi changes can take the radio off your mesh or off this Wi-Fi."));
}
$("own-save").onclick = async () => {
  const { ok, j } = await post("/api/radio", { owner: { long: $("own-long").value, short: $("own-short").value } });
  note("radio-note", j.message || (ok ? "Saved" : "Not saved"), !ok); if (ok) poll(true);
};
$("radio-save").onclick = async () => {
  if (!R) return;
  const changes = {}; const risky = [];
  for (const inp of $("radio-fields").querySelectorAll("[data-key]")) {
    const k = inp.dataset.key, t = inp.dataset.type, cur = R.values[k];
    let v;
    if (t === "bool") v = inp.checked; else if (t === "secret") { v = inp.value; if (!v) continue; }
    else if (t === "str") v = inp.value; else v = Number(inp.value);
    if (t !== "secret" && String(v) === String(t === "enum" ? cur : cur)) continue;
    changes[k] = v;
    if (inp.dataset.risky) risky.push(inp.parentNode.firstChild.textContent.replace(" *", ""));
  }
  if (!Object.keys(changes).length) { note("radio-note", "Nothing changed"); return; }
  let msg = "Save " + Object.keys(changes).length + " setting(s)? The radio restarts to apply them.";
  if (risky.length) msg += "\n\nCareful: " + risky.join(", ") + ". A wrong region is illegal in some places; a different preset or Wi-Fi network can take the radio off your mesh or off this Wi-Fi.";
  if (S.conn && S.conn.startsWith("Wi-Fi") && changes["network.wifi_enabled"] === false) msg += "\n\nPagerMesh talks to this radio over Wi-Fi: turning Wi-Fi off disconnects it.";
  if (!confirm(msg)) return;
  const { ok, j } = await post("/api/radio", { changes });
  note("radio-note", j.message || (ok ? "Saved" : "Not saved"), !ok);
  setTimeout(loadRadio, 1500);
};
$("radio-reboot").onclick = async () => {
  if (!confirm("Restart the radio?")) return;
  const { ok, j } = await post("/api/radio", { reboot: true });
  note("radio-note", j.message || "", !ok);
};
const ROLE = { 0: "Disabled", 1: "Primary", 2: "Secondary" };
let editIdx = null;
function drawChannels() {
  if (!R) return;
  const tb = $("chan-rows"); tb.innerHTML = "";
  for (const c of R.channels) {
    const tr = el("tr");
    for (const v of [c.index, c.name || (c.index === 0 ? "(default)" : ""), ROLE[c.role] || c.role, c.psk_kind]) tr.appendChild(el("td", "", String(v)));
    const td = el("td"); td.appendChild(btn("Edit", () => editChannel(c.index))); tr.appendChild(td);
    tb.appendChild(tr);
  }
  const used = new Set(R.channels.map((c) => c.index));
  let free = null; for (let i = 1; i < 8; i++) if (!used.has(i)) { free = i; break; }
  $("chan-add").disabled = free == null;
  $("chan-add").onclick = () => editChannel(free, true);
}
function editChannel(idx, isNew) {
  const c = (R.channels.find((x) => x.index === idx)) || { index: idx, name: "", role: 2, uplink: false, downlink: false, precision: 0, psk_kind: "none" };
  editIdx = idx;
  $("chan-edit").classList.remove("hidden");
  $("ce-title").textContent = (isNew ? "New channel " : "Channel ") + idx;
  $("ce-name").value = c.name || "";
  $("ce-role").value = String(isNew ? 2 : c.role);
  $("ce-psk").value = isNew ? "random" : "keep";
  $("ce-up").checked = !!c.uplink; $("ce-down").checked = !!c.downlink;
  $("ce-prec").value = String([0, 32, 16, 13, 11].includes(c.precision) ? c.precision : 0);
}
$("ce-cancel").onclick = () => { $("chan-edit").classList.add("hidden"); editIdx = null; };
$("ce-save").onclick = async () => {
  if (editIdx == null) return;
  const body = { index: editIdx, name: $("ce-name").value, role: Number($("ce-role").value), psk: $("ce-psk").value,
    uplink: $("ce-up").checked, downlink: $("ce-down").checked, precision: Number($("ce-prec").value) };
  let msg = "Save channel " + editIdx + "? Radios need the same channel name and key to talk on it.";
  if (body.psk !== "keep") msg += "\n\nThe key changes: everyone on this channel needs the new share link / QR.";
  if (body.role === 0) msg += "\n\nThis turns the channel off.";
  if (!confirm(msg)) return;
  const { ok, j } = await post("/api/channel", body);
  note("chan-note", j.message || (ok ? "Saved" : "Not saved"), !ok);
  if (ok) { $("chan-edit").classList.add("hidden"); editIdx = null; setTimeout(loadRadio, 800); }
};
$("chan-share").onclick = async () => {
  const box = $("chan-qr");
  if (!box.classList.contains("hidden")) { box.classList.add("hidden"); box.innerHTML = ""; return; }
  if (!confirm("Show the share link and QR code? They hold your channel keys - show them only to people who should join.")) return;
  const { ok, j } = await post("/api/radio/share", {});
  if (!ok) { note("chan-note", j.message || "Not available", true); return; }
  box.innerHTML = "";
  if (j.svg) { const img = el("img"); img.alt = "Channel QR code"; img.src = "data:image/svg+xml;base64," + btoa(j.svg); box.appendChild(img); }
  box.appendChild(el("code", "", j.url));
  box.appendChild(btn("Copy link", () => navigator.clipboard && navigator.clipboard.writeText(j.url).then(() => toast("Link copied"))));
  box.appendChild(btn("Hide", () => { box.classList.add("hidden"); box.innerHTML = ""; }));
  box.classList.remove("hidden");
};

// ---- Settings: PagerMesh options and the TAK bridge
function drawApp() {
  const c = S.cfg || {};
  if (document.activeElement !== $("app-dm")) $("app-dm").value = c.dm_alert || "sound";
  const ps = $("app-pos");
  if (document.activeElement !== ps) {
    ps.innerHTML = "";
    const off = el("option", "", "nobody (position not shared)"); off.value = ""; ps.appendChild(off);
    for (const ch of S.channels) {
      const o = el("option", "", ch.index + ": " + ch.name + (ch.private ? " (own key)" : " (public key)"));
      o.value = ch.index; ps.appendChild(o);
    }
    ps.value = c.pos_chan || "";
  }
  posWarn();
  const mp = manualPos();
  $("app-manual").textContent = mp ? "Location set on the map: " + mp[0].toFixed(5) + ", " + mp[1].toFixed(5) + " (used when the Pager has no GPS fix)" : "No map-set location.";
  $("app-clear-manual").disabled = !mp;
}
function posWarn() {
  const v = $("app-pos").value, ch = (S.channels || []).find(x => String(x.index) === v);
  $("app-pos-warn").textContent = ch && !ch.private ? ch.name + " is a public channel: anyone on it can see where the Pager is." : "";
}
$("app-pos").onchange = async () => { posWarn(); const { ok, j } = await post("/api/cfg", { pos_chan: $("app-pos").value }); note("app-note", ok ? "Saved" : j.message, !ok); };
$("app-dm").onchange = async () => { const { ok, j } = await post("/api/cfg", { dm_alert: $("app-dm").value }); note("app-note", ok ? "Saved" : j.message, !ok); };
$("app-clear-manual").onclick = clearManual;
function drawTakForm() {
  const c = S.cfg || {};
  $("tak-on").checked = c.tak_on === "1";
  $("tak-proto").value = c.tak_proto || "tls";
  $("tak-host").value = c.tak_host || "";
  $("tak-port").value = c.tak_port || "";
  $("tak-pos").checked = (c.tak_pos || "1") === "1";
  $("tak-chat").checked = (c.tak_chat || "1") === "1";
  const sel = $("tak-chan"); sel.innerHTML = "";
  const none = el("option", "", "none (chat paused)"); none.value = ""; sel.appendChild(none);
  for (const ch of S.channels) {
    const o = el("option", "", ch.index + ": " + ch.name + (ch.private ? " (own key)" : " (public key - not allowed)"));
    o.value = ch.index; o.disabled = !ch.private; sel.appendChild(o);
  }
  sel.value = c.tak_chan || "";
  drawTakStatus();
}
function drawTakStatus() {
  const b = S.bridge || {};
  $("tak-status").textContent = b.on ? "(" + b.status + ")" : "(off)";
  if (!b.on) $("tak-cert").textContent = "";
  else $("tak-cert").textContent = "Status: " + b.status + (b.error ? " - " + b.error : "") + (b.chat ? " · " + b.chat : "") + " · sent " + (b.sent || 0) + ", from TAK " + (b.received || 0) +
    ", to mesh " + (b.to_mesh || 0) + (b.proto === "tls" ? " · " + (b.has_cert ? "certificate: " + b.cert : "no client.pem yet (certs/ folder, see README)") : "");
}
$("tak-proto").onchange = () => { $("tak-port").placeholder = $("tak-proto").value === "tls" ? "8089" : "8087"; };
$("tak-save").onclick = async () => {
  const body = { tak_on: $("tak-on").checked ? "1" : "0", tak_proto: $("tak-proto").value, tak_host: $("tak-host").value.trim(),
    tak_port: $("tak-port").value || ($("tak-proto").value === "tls" ? "8089" : "8087"), tak_pos: $("tak-pos").checked ? "1" : "0",
    tak_chat: $("tak-chat").checked ? "1" : "0", tak_chan: $("tak-chan").value };
  if (body.tak_on === "1" && !body.tak_host) { note("tak-note", "Enter the TAK server address", true); return; }
  const { ok, j } = await post("/api/cfg", body);
  note("tak-note", ok ? "Saved - the bridge reconnects" : j.message, !ok);
  if (ok) setTimeout(() => poll(true), 1500);
};

// ---- top bar
function drawTop() {
  $("who").innerHTML = esc(S.me.long || S.me.short || "Pager") + "<small>" + esc(S.me.id) + "</small>";
  const link = $("p-link");
  link.textContent = "Mesh: " + S.link;
  link.className = "pill " + (S.link === "connected" ? "ok" : S.link === "connecting" || S.link === "starting" ? "warn" : "bad");
  const rg = $("p-region");
  rg.textContent = "Region: " + (S.region || "?");
  rg.className = "pill " + (S.region === "UNSET" ? "bad" : S.region ? "ok" : "");
  const g = $("p-gps");
  g.textContent = S.gps.fix ? "GPS fix (" + S.gps.sats + ")" : "GPS: no fix";
  g.className = "pill " + (S.gps.fix ? "ok" : "warn");
  $("p-nodes").textContent = Math.max(0, S.nodes.length - 1) + " nodes";
  $("conn-now").textContent = S.setup ? "Not set up yet." : "Now: " + S.conn + " (" + S.link + ")";
  $("setup-bar").classList.toggle("hidden", !S.setup);
  if (S.setup && tab !== "settings") document.querySelector('[data-tab="settings"]').click();
  for (const t of ["nodes", "chat", "sigint"]) document.querySelector('[data-tab="' + t + '"]').classList.toggle("hidden", !!S.setup);
  $("more-settings").classList.toggle("hidden", !!S.setup);
  showNotes();
  drawTakStatus();
  $("b-pos").classList.toggle("hidden", !!S.setup);
  const w = $("warn");
  let msg = "";
  if (S.setup) msg = "";
  else if (S.link !== "connected") msg = "Not connected to meshtasticd" + (S.error ? ": " + S.error : "") + " - retrying.";
  else if (S.region === "UNSET") msg = "Radio region is not set: Settings > Radio settings > Region.";
  w.textContent = msg; w.classList.toggle("hidden", !msg);
  const u = $("unread");
  u.textContent = S.unread; u.classList.toggle("hidden", !S.unread || tab === "chat");
}

// ---- settings: radio connection
let setupLoaded = false;
function connValue() { const r = document.querySelector('input[name="conn"]:checked'); return r ? r.value : ""; }
function showConnFields() {
  const c = connValue();
  $("f-wifi").classList.toggle("hidden", c !== "wifi");
  $("f-usb").classList.toggle("hidden", c !== "usb");
}
for (const r of document.querySelectorAll('input[name="conn"]')) r.onchange = showConnFields;

function fillPorts(ports, cur) {
  const sel = $("s-dev");
  sel.innerHTML = "";
  if (!ports.length) {
    const o = document.createElement("option"); o.value = ""; o.textContent = "No USB radio found - plug it in and Rescan"; sel.appendChild(o);
  }
  for (const p of ports) {
    const o = document.createElement("option"); o.value = p.dev; o.textContent = p.label; o.disabled = p.gps; sel.appendChild(o);
  }
  if (cur && ports.some((p) => p.dev === cur)) sel.value = cur;
}

// the form stays locked until the current settings are in, so a late load never overwrites typing
function lockSetup(on) { for (const x of $("setup-form").querySelectorAll("input, select, button")) x.disabled = on; }
async function loadSetup(force) {
  if (setupLoaded && !force) return;
  if (!setupLoaded) { lockSetup(true); setupNote("Loading the current settings..."); }
  const r = await api("/api/setup");
  const j = await r.json();
  const first = !setupLoaded;
  setupLoaded = true;
  lockSetup(false);
  if (first) setupNote("");
  if (!force) {
    const want = j.setup && !j.conn ? "" : j.conn;
    for (const x of document.querySelectorAll('input[name="conn"]')) x.checked = x.value === want;
    $("s-host").value = j.host || "";
    $("s-port").value = j.port || 4403;
  }
  fillPorts(j.ports, j.dev);
  showConnFields();
}
$("s-rescan").onclick = () => loadSetup(true);

function setupBody() {
  return { conn: connValue(), host: $("s-host").value.trim(), port: Number($("s-port").value) || 4403, dev: $("s-dev").value };
}
function setupNote(msg, bad) { const n = $("setup-note"); n.textContent = msg; n.style.color = bad ? "var(--bad)" : "var(--acc)"; }

$("s-test").onclick = async () => {
  setupNote("Testing... (up to 20 s)");
  $("s-test").disabled = true;
  try {
    const r = await api("/api/setup/test", setupBody());
    const j = await r.json().catch(() => ({}));
    setupNote((j.ok ? "\u2713 " : "\u2717 ") + (j.message || "failed"), !j.ok);
  } finally { $("s-test").disabled = false; }
};
$("setup-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const r = await api("/api/setup/save", setupBody());
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { setupNote(j.message || "Not saved", true); return; }
  if (j.live) { waitForSwitch(setupBody()); return; }
  setupNote("Saved. The Pager is restarting PagerMesh with the new radio - this page reloads by itself...");
  waitForRestart();
});

// Normal use: the service switched to the new radio itself. Show the result, no reload.
async function waitForSwitch(want) {
  const where = want.conn === "wifi" ? want.host + ":" + want.port : want.conn === "usb" ? want.dev : "Glytch Mesh Mod";
  setupNote("Saved. Connecting to " + where + "...");
  const until = Date.now() + 60000;
  while (Date.now() < until) {
    await new Promise((res) => setTimeout(res, 2000));
    try {
      const r = await api("/api/state");
      if (!r.ok) continue;
      const j = await r.json();
      if (j.link === "connected") { setupNote("\u2713 Saved and connected to " + where + "."); loadSetup(true); poll(true); return; }
    } catch (err) { /* keep waiting */ }
  }
  setupNote("Saved " + where + ", but no answer from the radio yet. PagerMesh keeps trying.", true);
}

// After Save the Pager restarts the service (new sign-in needed). Wait for it, then reload.
async function waitForRestart() {
  const until = Date.now() + 90000;
  await new Promise((res) => setTimeout(res, 3000));
  while (Date.now() < until) {
    try {
      const r = await fetch("/api/state", { cache: "no-store" });
      if (r.status === 401) { $("login-err").textContent = "PagerMesh restarted - sign in again."; showLogin(); return; }
      if (r.ok) { const j = await r.json(); if (!j.setup) { location.reload(); return; } }
    } catch (err) { /* restarting: not answering yet */ }
    await new Promise((res) => setTimeout(res, 2000));
  }
  setupNote("The Pager did not come back yet. Check the Pager screen, then reload this page.", true);
}

// ---- polling
async function poll(force) {
  try {
    const r = await api("/api/state" + (force ? "" : "?v=" + ver));
    if (r.status === 200) {
      S = await r.json();
      ver = S.version;
      if (!$("app").classList.contains("hidden")) {
        drawTop(); drawNodes(); drawDest(); drawChat(); drawMap();
        if (tab === "chat" && curConv) markRead();
      }
    }
  } catch (e) { /* offline or signed out */ }
}

(async function start() {
  const r = await fetch("/api/state");
  if (r.status === 401) showLogin();
  else { showApp(); poll(true); }
  setInterval(() => poll(false), 2000);
  setInterval(() => poll(true), 30000);       // ages ("heard 3m ago") keep moving
})();
