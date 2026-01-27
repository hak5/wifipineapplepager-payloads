function createModal(id, title, contentHTML, showRefresh = false) {
    if (document.getElementById(id)) return;
    const style = document.createElement("style");
    style.textContent = `
        .modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); z-index: 9999; display: flex; align-items: center; justify-content: center; backdrop-filter: blur(2px); }
        .modal { background: #1e1e1e; color: #fff; border-radius: 10px; width: 480px; max-width: 95%; padding: 20px; box-shadow: 0 10px 40px rgba(0,0,0,.6); font-family: sans-serif; position: relative; z-index: 10000; display: flex; flex-direction: column; max-height: 90vh; }
        .modal-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
        .modal h2 { margin: 0; font-size: 20px; color: #fff; font-weight: 600; }
        .modal-hr { border: 0; height: 1px; background: #333; margin: 0 0 18px 0; }
        .modal-content { overflow-y: auto; flex: 1; padding-right: 5px; }
        .modal-content::-webkit-scrollbar { width: 6px; }
        .modal-content::-webkit-scrollbar-thumb { background: #444; border-radius: 10px; }
        .modal .modal-close, .modal .modal-reset, .btn-apply, .btn-unapply, .btn-color-reset { 
            margin-top: 8px; width: 100%; padding: 10px; border-radius: 6px; border: none; cursor: pointer; 
            font-weight: 600; font-size: 14px; transition: transform 0.1s, background 0.2s, filter 0.2s; 
        }
        .modal .modal-close { background: #ff5252; color: #fff; flex-shrink: 0; }
        .btn-update-info { 
            background: #007acc; color: #fff; border: none; padding: 8px 16px; border-radius: 4px; 
            cursor: pointer; font-size: 13px; font-weight: 600; transition: transform 0.1s, filter 0.2s; 
        }
        .btn-update-info:active, .btn-apply:active, .btn-unapply:active { transform: scale(0.92); filter: brightness(1.2); }
        .sys-info-box { background: #2b2b2b; padding: 15px; border-radius: 6px; margin-bottom: 12px; border-left: 4px solid #444; }
        .sys-info-label { color: #aaa; font-size: 12px; text-transform: uppercase; font-weight: bold; margin-bottom: 6px; letter-spacing: 0.5px; }
        .sys-info-value { color: #00ffaa; font-family: monospace; font-size: 15px; font-weight: 500; }
        .sys-table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }
        .sys-table th { text-align: left; color: #888; padding-bottom: 8px; text-transform: uppercase; font-size: 10px; letter-spacing: 1px; }
        .sys-table td { padding: 10px 4px; border-bottom: 1px solid #333; white-space: nowrap; }
        .sys-dev { font-weight: bold; color: #eee; }
        .sys-total { color: #00ffaa; text-align: center; }
        .sys-used { color: #ffae42; text-align: center; }
        .sys-avail { color: #00ffaa; text-align: right; }
        .modal-links { display: flex; flex-direction: column; gap: 8px; }
        .modal-links .lib-item { display: flex; align-items: center; padding: 12px; border-radius: 6px; background: #2b2b2b; color: #fff; gap: 10px; cursor: pointer; transition: background 0.2s; }
        .modal-links .lib-item:hover { background: #383838; }
        .btn-apply { background: #007acc; color: #fff; width: auto; padding: 6px 14px; font-size: 13px; min-width: 80px; margin-top: 0 !important; }
        .btn-unapply { background: #ff5252; color: #fff; width: auto; padding: 6px 14px; font-size: 13px; min-width: 80px; margin-top: 0 !important; }
        .btn-color-reset { background: #555; color: #fff; width: auto; padding: 6px 12px; font-size: 12px; margin-top: 0; }
        .modal-reset { background: #444; color: white; width: 100%; }
        .btn-io { background: #444; color: #fff; padding: 8px; border-radius: 4px; font-size: 12px; cursor: pointer; border: 1px solid #555; flex: 1; text-align: center; }
        .btn-io:hover { background: #555; }
        .btn-tab { background: #333; color: #aaa; padding: 10px; border-radius: 4px; font-size: 13px; cursor: pointer; border: none; flex: 1; text-align: center; font-weight: 600; }
        .btn-tab.active { background: #007acc; color: #fff; }
        input[type="color"] { -webkit-appearance: none; width: 60px; height: 38px; border: none; padding: 0; background: none; cursor: pointer; }
        input[type="color"]::-webkit-color-swatch { border: 1px solid #333; border-radius: 6px; }
        .loader { border: 4px solid #333; border-top: 4px solid #007acc; border-radius: 50%; width: 30px; height: 30px; animation: spin 1s linear infinite; margin: 20px auto; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    `;
    document.head.appendChild(style);
    const overlay = document.createElement("div");
    overlay.className = "modal-overlay";
    overlay.id = id;
    overlay.style.display = "none";
    overlay.innerHTML = `
        <div class="modal" onclick="event.stopPropagation()">
            <div class="modal-header">
                <h2>${title}</h2>
                ${showRefresh ? `<button class="btn-update-info" id="${id}Update">Update</button>` : ''}
            </div>
            <hr class="modal-hr">
            <div class="modal-content">${contentHTML}</div>
            <button class="modal-close">Close</button>
        </div>`;
    document.body.appendChild(overlay);
    overlay.querySelector(".modal-close").onclick = () => overlay.style.display = "none";
    overlay.onclick = (e) => { if (e.target === overlay) overlay.style.display = "none"; };
}

function showModal(id) {
    const overlay = document.getElementById(id);
    if (overlay) overlay.style.display = "flex";
}

async function sendServerRequest(action, data, returnJson = false, authenticated = true) {
    const url = new URL(`http://${window.location.hostname}:4040/cgi-bin/api.sh`);
    url.searchParams.set("action", action);
    if (authenticated) {
        const serverid = localStorage.getItem("serverid");
        if (!serverid) return;
        const cookieName = `AUTH_${serverid}`;
        const cookieValue = document.cookie.split("; ").find(c => c.startsWith(cookieName + "="));
        if (!cookieValue) return;
        url.searchParams.set("token", cookieValue.substring(cookieName.length + 1));
        url.searchParams.set("serverid", serverid);
    }
    const options = { method: action === "setconfig" ? "POST" : "GET" };
    if (action === "setconfig") options.body = data;
    else if (data) url.searchParams.set("data", data);
    try {
        const r = await fetch(url.toString(), options);
        return returnJson ? await r.json() : r;
    } catch(e) { console.error(e); }
}

async function getFullConfig() {
    const res = await sendServerRequest("listconfig", undefined, true, false);
    return res?.config || {};
}

async function saveFullConfig(newData) {
    const current = await getFullConfig();
    const merged = { ...current, ...newData };
    await sendServerRequest("setconfig", JSON.stringify(merged), false, true);
    return merged;
}

function applyBackgroundTheme(value, isColorOnly = false) {
    if (!value) return;
    let styleTag = document.getElementById("dynamic-skinner-css");
    if (!styleTag) {
        styleTag = document.createElement("style");
        styleTag.id = "dynamic-skinner-css";
        document.head.appendChild(styleTag);
    }
    const isImage = !isColorOnly && (value.startsWith("data:") || value.startsWith("http"));
    const cssRule = isImage 
        ? `background-image: url("${value}") !important; background-size: cover !important; background-position: center !important; background-repeat: no-repeat !important; background-attachment: fixed !important;` 
        : `background-color: ${value} !important; background-image: none !important;`;
    styleTag.textContent = `body, #sidebarnav, #sidebarbutton, #sidebarbutton.toggle { ${cssRule} }`;
}

function applyPagerTheme(config) {
    const fillEl = document.getElementById("pager-custom-fill");
    const borderEl = document.getElementById("pager-custom-border");
    const imageEl = document.getElementById("pager-custom-image");
    
    if (!fillEl || !borderEl || !imageEl) return;

    const defaultColor = "#fff200";
    const color = config.pagerHex || defaultColor;
    const activeSkinName = config.appliedPagerSkinName;
    const skins = config.savedPagerSkins || [];
    const activeSkin = skins.find(s => s.name === activeSkinName);

    if (activeSkin) {
        fillEl.style.display = "none";
        borderEl.style.display = "none";
        imageEl.style.display = "block";
        imageEl.src = activeSkin.url;
    } else {
        fillEl.style.display = "block";
        borderEl.style.display = "block";
        imageEl.style.display = "none";
        fillEl.querySelectorAll("path, rect, circle, polygon, ellipse").forEach(el => el.style.fill = color);
    }
}

async function updateSystemData() {
    const container = document.getElementById("systemInfoContent");
    const res = await sendServerRequest("systeminfo", undefined, true, true);
    if (res?.status === "ok") {
        const diskLines = res.data.disk.split(',').map(d => {
            const parts = d.trim().split(/\s+/);
            if (parts.length < 4) return "";
            return `<tr><td class="sys-dev">${parts[0]}</td><td class="sys-total">${parts[1]}</td><td class="sys-used">${parts[2]}</td><td class="sys-avail">${parts[3]}</td></tr>`;
        }).join('');
        container.innerHTML = `
            <div class="sys-info-box"><div class="sys-info-label">CPU Load</div><div class="sys-info-value">${res.data.cpu_load}</div></div>
            <div class="sys-info-box"><div class="sys-info-label">Memory</div><div class="sys-info-value">${res.data.memory}</div></div>
            <div class="sys-info-box"><div class="sys-info-label">Disk Usage</div>
            <table class="sys-table"><thead><tr><th>Mount</th><th style="text-align:center">Size</th><th style="text-align:center">Used</th><th style="text-align:right">Available</th></tr></thead>
            <tbody>${diskLines}</tbody></table></div>`;
    }
}

function initSystemInfo() {
    createModal("systemInfoModal", "System Information", '<div id="systemInfoContent">Fetching data...</div>', true);
    document.getElementById("systemInfoModalUpdate").onclick = updateSystemData;
    const ul = document.querySelector("#sidebarnav ul");
    if (!ul || document.getElementById("systemInfoBtn")) return;
    const li = document.createElement("li");
    li.innerHTML = `<a href="#" id="systemInfoBtn"><i class="material-icons">info</i><div class="sidebarsub">System Info<div class="sidebarmini">View your systems information.</div></div></a>`;
    ul.appendChild(li);
    document.getElementById("systemInfoBtn").onclick = (e) => { e.preventDefault(); showModal("systemInfoModal"); updateSystemData(); };
}

function initLootUI() {
    createModal("lootModal", "Download Specific Loot", '<div class="modal-links"></div>');
    const ul = document.querySelector("#sidebarnav ul");
    if (!ul || document.getElementById("lootSidebarBtn")) return;
    const li = document.createElement("li");
    li.innerHTML = `<a href="#" id="lootSidebarBtn"><i class="material-icons">download</i><div class="sidebarsub">Download Specific Loot<div class="sidebarmini">Download a specific loot folder from /root/loot</div></div></a>`;
    ul.appendChild(li);
    document.getElementById("lootSidebarBtn").onclick = async e => {
        e.preventDefault();
        showModal("lootModal");
        const container = document.querySelector("#lootModal .modal-links");
        container.innerHTML = 'Fetching loot...';
        const res = await sendServerRequest("command", "ls /root/loot/ | tr '\\n' ','", true);
        if (res?.status === "done") {
            const list = res.output.trim().split(",").filter(Boolean);
            container.innerHTML = "";
            list.forEach(dir => {
                const a = document.createElement("div");
                a.className = "lib-item"; 
                a.innerHTML = `<i class="material-icons">folder</i> <span>${dir.trim()}</span>`;
                a.onclick = () => window.location.href = `/api/files/zip/root/loot/${dir.trim()}`;
                container.appendChild(a);
            });
        }
    };
}

let isUpdatingPayloads = false;
function initPayloadUpdater() {
    createModal("payloadModal", "Update Payloads", '<div id="payloadUpdateContent" style="display:flex;flex-direction:column;align-items:center;justify-content:center;padding:20px;"><p style="text-align:center;color:#ccc;margin-bottom:15px;">Update your local payload library from the official repository. <br><br>This will overwrite all your payloads!</p><button id="btnRunUpdate" class="btn-update-info">Update Now</button></div>');
    const ul = document.querySelector("#sidebarnav ul");
    if (!ul || document.getElementById("payloadUpdateBtn")) return;
    const li = document.createElement("li");
    li.innerHTML = `<a href="#" id="payloadUpdateBtn"><i class="material-icons">system_update_alt</i><div class="sidebarsub">Update Payloads<div class="sidebarmini">Update payload library</div></div></a>`;
    ul.appendChild(li);
    document.getElementById("payloadUpdateBtn").onclick = (e) => {
        e.preventDefault();
        showModal("payloadModal");
        if (isUpdatingPayloads) return;
        const container = document.getElementById("payloadUpdateContent");
        container.innerHTML = '<p style="text-align:center;color:#ccc;margin-bottom:15px;">Update your local payload library from the official repository. <br><br>This will overwrite all your payloads!</p><button id="btnRunUpdate" class="btn-update-info">Update Now</button>';
        document.getElementById("btnRunUpdate").onclick = async () => {
            isUpdatingPayloads = true;
            container.innerHTML = '<div class="loader"></div><div style="margin-top:15px;color:#aaa;">Updating payloads...</div>';
            const res = await sendServerRequest("updatepayloads", undefined, true, true);
            if (res && res.okay) {
                container.innerHTML = `<i class="material-icons" style="font-size:40px;color:#00ffaa;margin-bottom:10px;">check_circle</i><div style="color:#fff;">${res.message}</div>`;
            } else {
                container.innerHTML = `<i class="material-icons" style="font-size:40px;color:#ff5252;margin-bottom:10px;">error</i><div style="color:#fff;">${res?.error || "Update failed"}</div>`;
            }
            isUpdatingPayloads = false;
        };
    };
}

function initPagerSkinner() {
    const defaultBgHex = "#303030";
    const defaultPagerHex = "#fff200";
    const MAX_FILE_SIZE = 500 * 1024;
    const contentHTML = `
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; gap:10px;">
            <div id="btnExport" class="btn-io">Export Theme</div>
            <div id="btnImport" class="btn-io">Import Theme</div>
            <input type="file" id="importFile" style="display:none;" accept=".json">
        </div>
        <div style="display:flex; gap:10px; margin-bottom:15px;">
            <div id="tabBackground" class="btn-tab active">Background</div>
            <div id="tabPager" class="btn-tab">Pager</div>
        </div>
        <hr class="modal-hr">
        
        <div id="sectionBackground">
            <h3 style="margin: 0 0 8px 0; font-size:14px; color:#ddd;">Background Color</h3>
            <div style="display:flex; align-items:center; gap:10px; margin-bottom:10px;">
                <input type="color" id="bgColorPicker" value="${defaultBgHex}">
                <button id="btnResetBg" class="btn-color-reset">Reset to Default</button>
            </div>
            <hr class="modal-hr">
            <h3 style="margin: 0 0 8px 0; font-size:14px; color:#ddd;">Upload Background Image <span style="font-size:11px; color:#888;">(Max 500KB)</span></h3>
            <input type="text" id="bgImgName" placeholder="Name" style="width:100%; box-sizing:border-box; padding:8px; border-radius:4px; border:1px solid #333; background:#2b2b2b; color:#fff; margin-bottom:10px;">
            <input type="file" id="bgImgFile" accept="image/*" style="width:100%; color:#aaa; font-size:12px; margin-bottom:10px;">
            <button id="btnUploadBg" class="modal-reset">Add to Library</button>
            <h3 style="margin: 15px 0 8px 0; font-size:14px; color:#ddd;">Background Library</h3>
            <div id="bgLibraryList" class="modal-links"></div>
        </div>

        <div id="sectionPager" style="display:none;">
            <h3 style="margin: 0 0 8px 0; font-size:14px; color:#ddd;">Pager Color</h3>
            <div style="display:flex; align-items:center; gap:10px; margin-bottom:10px;">
                <input type="color" id="pagerColorPicker" value="${defaultPagerHex}">
                <button id="btnResetPager" class="btn-color-reset">Reset to Default</button>
            </div>
            <hr class="modal-hr">
            <h3 style="margin: 0 0 8px 0; font-size:14px; color:#ddd;">Upload Pager Skin <span style="font-size:11px; color:#888;">(Max 500KB)</span></h3>
            <input type="text" id="pagerImgName" placeholder="Name" style="width:100%; box-sizing:border-box; padding:8px; border-radius:4px; border:1px solid #333; background:#2b2b2b; color:#fff; margin-bottom:10px;">
            <input type="file" id="pagerImgFile" accept="image/*" style="width:100%; color:#aaa; font-size:12px; margin-bottom:10px;">
            <div style="display:flex; gap:10px;">
                <button id="btnUploadPager" class="modal-reset">Add to Library</button>
                <button id="btnDownloadTemplate" class="modal-reset" style="background:#555;">Download Template</button>
            </div>
            <h3 style="margin: 15px 0 8px 0; font-size:14px; color:#ddd;">Pager Skin Library</h3>
            <div id="pagerLibraryList" class="modal-links"></div>
        </div>
    `;

    const renderLibraries = (config, overlay) => {
        const renderList = (listId, items, activeName, type) => {
            const listContainer = overlay.querySelector(listId);
            listContainer.innerHTML = items.length ? "" : "No items saved.";
            items.forEach((item, index) => {
                const isApplied = (activeName === item.name);
                const div = document.createElement("div");
                div.className = "lib-item";
                div.innerHTML = `<i class="material-icons">image</i><span style="flex:1;">${item.name}</span><button class="${isApplied ? 'btn-unapply' : 'btn-apply'}">${isApplied ? 'Unapply' : 'Apply'}</button><i class="material-icons delete-btn" style="color:#ff5252;">delete</i>`;
                
                div.querySelector(isApplied ? ".btn-unapply" : ".btn-apply").onclick = async (e) => {
                    e.stopPropagation();
                    const updateData = {};
                    const keyName = type === "bg" ? "appliedBackgroundName" : "appliedPagerSkinName";
                    updateData[keyName] = isApplied ? "" : item.name;
                    const updated = await saveFullConfig(updateData);
                    loadConfigAndApply(updated);
                    renderLibraries(updated, overlay);
                };

                div.querySelector(".delete-btn").onclick = async (e) => {
                    e.stopPropagation();
                    if(!confirm(`Delete "${item.name}"?`)) return;
                    items.splice(index, 1);
                    const updateData = {};
                    updateData[type === "bg" ? "savedBackgrounds" : "savedPagerSkins"] = items;
                    if (activeName === item.name) {
                        updateData[type === "bg" ? "appliedBackgroundName" : "appliedPagerSkinName"] = "";
                    }
                    const updated = await saveFullConfig(updateData);
                    loadConfigAndApply(updated);
                    renderLibraries(updated, overlay);
                };
                listContainer.appendChild(div);
            });
        };

        renderList("#bgLibraryList", config.savedBackgrounds || [], config.appliedBackgroundName || "", "bg");
        renderList("#pagerLibraryList", config.savedPagerSkins || [], config.appliedPagerSkinName || "", "pager");
    };

    createModal("pagerSkinnerModal", "Pager Skinner Settings", contentHTML);
    const overlay = document.getElementById("pagerSkinnerModal");
    const bgPicker = overlay.querySelector("#bgColorPicker");
    const pagerPicker = overlay.querySelector("#pagerColorPicker");
    const tabBg = overlay.querySelector("#tabBackground");
    const tabPager = overlay.querySelector("#tabPager");
    const secBg = overlay.querySelector("#sectionBackground");
    const secPager = overlay.querySelector("#sectionPager");

    tabBg.onclick = () => { tabBg.classList.add("active"); tabPager.classList.remove("active"); secBg.style.display = "block"; secPager.style.display = "none"; };
    tabPager.onclick = () => { tabPager.classList.add("active"); tabBg.classList.remove("active"); secPager.style.display = "block"; secBg.style.display = "none"; };

    overlay.querySelector("#btnDownloadTemplate").onclick = async () => {
        const r = await sendServerRequest("getimage", "pager-template.png", false);
        if (r && r.ok) {
            const blob = await r.blob();
            const url = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = url;
            a.download = "pager-template.png";
            a.click();
            URL.revokeObjectURL(url);
        } else {
            alert("Could not download template.");
        }
    };

    overlay.querySelector("#btnExport").onclick = async () => {
        const config = await getFullConfig();
        const blob = new Blob([JSON.stringify(config, null, 2)], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "skinner_config.json";
        a.click();
        URL.revokeObjectURL(url);
    };

    const importInput = overlay.querySelector("#importFile");
    overlay.querySelector("#btnImport").onclick = () => importInput.click();
    importInput.onchange = (e) => {
        const file = e.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = async (ev) => {
            try {
                const importedConfig = JSON.parse(ev.target.result);
                const updated = await saveFullConfig(importedConfig);
                loadConfigAndApply(updated);
                renderLibraries(updated, overlay);
                if (updated.backgroundHex) bgPicker.value = updated.backgroundHex;
                if (updated.pagerHex) pagerPicker.value = updated.pagerHex;
                alert("Theme imported successfully!");
            } catch (err) { alert("Failed to import. Invalid JSON file."); }
        };
        reader.readAsText(file);
    };

    const handleUpload = async (nameInputId, fileInputId, configKey) => {
        const n = overlay.querySelector(nameInputId), f = overlay.querySelector(fileInputId), file = f.files[0];
        if (!n.value || !file) return alert("Missing name or file.");
        if (file.size > MAX_FILE_SIZE) { alert(`File too large (${(file.size / 1024).toFixed(1)}KB). Please keep images under 500KB.`); f.value = ""; return; }
        const r = new FileReader();
        r.onload = async (e) => {
            const config = await getFullConfig();
            const items = config[configKey] || [];
            items.push({ name: n.value, url: e.target.result });
            const updateData = {};
            updateData[configKey] = items;
            const updated = await saveFullConfig(updateData);
            n.value = ""; f.value = "";
            renderLibraries(updated, overlay);
        };
        r.readAsDataURL(file);
    };

    overlay.querySelector("#btnUploadBg").onclick = () => handleUpload("#bgImgName", "#bgImgFile", "savedBackgrounds");
    overlay.querySelector("#btnUploadPager").onclick = () => handleUpload("#pagerImgName", "#pagerImgFile", "savedPagerSkins");

    bgPicker.oninput = (e) => applyBackgroundTheme(e.target.value, true);
    bgPicker.onchange = async (e) => { 
        const updated = await saveFullConfig({ backgroundHex: e.target.value, appliedBackgroundName: "" }); 
        renderLibraries(updated, overlay); 
    };
    overlay.querySelector("#btnResetBg").onclick = async () => { 
        const updated = await saveFullConfig({ backgroundHex: defaultBgHex, appliedBackgroundName: "" }); 
        applyBackgroundTheme(defaultBgHex, true); 
        bgPicker.value = defaultBgHex; 
        renderLibraries(updated, overlay); 
    };

    pagerPicker.oninput = (e) => {
        const fillEl = document.getElementById("pager-custom-fill");
        if(fillEl) fillEl.querySelectorAll("path, rect, circle, polygon, ellipse").forEach(el => el.style.fill = e.target.value);
    };
    pagerPicker.onchange = async (e) => { 
        const updated = await saveFullConfig({ pagerHex: e.target.value, appliedPagerSkinName: "" }); 
        loadConfigAndApply(updated); 
        renderLibraries(updated, overlay); 
    };
    overlay.querySelector("#btnResetPager").onclick = async () => { 
        const updated = await saveFullConfig({ pagerHex: defaultPagerHex, appliedPagerSkinName: "" }); 
        loadConfigAndApply(updated); 
        pagerPicker.value = defaultPagerHex; 
        renderLibraries(updated, overlay); 
    };

    const ul = document.querySelector("#sidebarnav ul");
    if (!ul || document.getElementById("pagerSkinnerBtn")) return;
    const li = document.createElement("li");
    li.innerHTML = `<a href="#" id="pagerSkinnerBtn"><i class="material-icons">color_lens</i><div class="sidebarsub">Pager Skinner<div class="sidebarmini">Skin your pager</div></div></a>`;
    ul.appendChild(li);
    document.getElementById("pagerSkinnerBtn").onclick = async (e) => { 
        e.preventDefault(); 
        showModal("pagerSkinnerModal"); 
        const config = await getFullConfig(); 
        if (config.backgroundHex) bgPicker.value = config.backgroundHex;
        if (config.pagerHex) pagerPicker.value = config.pagerHex;
        renderLibraries(config, overlay); 
    };
}

async function loadConfigAndApply(providedConfig = null) {
    const config = providedConfig || await getFullConfig();
    
    if (config.appliedBackgroundName) {
        const activeObj = (config.savedBackgrounds || []).find(b => b.name === config.appliedBackgroundName);
        if (activeObj) applyBackgroundTheme(activeObj.url);
    } else {
        applyBackgroundTheme(config.backgroundHex || "#303030", true);
    }
    
    applyPagerTheme(config);
}

async function initPagerSVG() {
    const t = document.getElementById("pager_ui");
    if (!t) return;

    const [rSvg, rBorder] = await Promise.all([
        sendServerRequest("getimage", "pager-fill.svg", false),
        sendServerRequest("getimage", "pager-border.png", false)
    ]);

    if (rSvg && rSvg.ok && rBorder && rBorder.ok) {
        const svgContent = await rSvg.text();
        const borderBlob = await rBorder.blob();
        const borderUrl = URL.createObjectURL(borderBlob);

        const w = document.createElement("div");
        w.id = "pager-custom-wrapper";
        w.style.cssText = "position:relative;display:inline-block;";
        t.parentNode.insertBefore(w, t);
        
        const svgDiv = document.createElement("div");
        svgDiv.id = "pager-custom-fill";
        svgDiv.style.cssText = "position:absolute;top:0;left:0;z-index:0;width:100%;height:100%;";
        svgDiv.innerHTML = svgContent;
        w.appendChild(svgDiv);

        const customImg = document.createElement("img");
        customImg.id = "pager-custom-image";
        customImg.style.cssText = "position:absolute;top:0;left:0;z-index:0;width:100%;height:100%;display:none;";
        w.appendChild(customImg);

        const borderImg = document.createElement("img");
        borderImg.id = "pager-custom-border";
        borderImg.src = borderUrl;
        borderImg.style.cssText = "position:absolute;top:0;left:0;z-index:1;width:100%;height:100%;pointer-events:none;"; 
        w.appendChild(borderImg);

        w.appendChild(t);
        t.style.position = "relative";
        t.style.zIndex = "2";

        t.querySelectorAll("img").forEach(i => {
            if (i.src.includes("virtual_pager")) i.remove();
        });

        const config = await getFullConfig();
        applyPagerTheme(config);
    }
}

function startInitialization() {
    let initialized = false;
    let lastSidebarState = false;

    loadConfigAndApply();

    const checkState = async () => {
        const sidebar = document.getElementById("sidebarnav");
        const isSidebarVisible = sidebar && sidebar.offsetParent !== null && window.getComputedStyle(sidebar).display !== 'none';

        if (isSidebarVisible && !initialized) {
            initPagerSVG();
            initLootUI();
            initPagerSkinner();
            initPayloadUpdater();
            initSystemInfo();
            fetch("/api/api_ping").then(res => res.json()).then(data => { if (data.serverid) localStorage.setItem("serverid", data.serverid); }).catch(()=>{});
            initialized = true;
        }

        if (isSidebarVisible !== lastSidebarState) {
            lastSidebarState = isSidebarVisible;
            if (isSidebarVisible) {
                const config = await getFullConfig();
                applyPagerTheme(config);
            }
        }
    };

    const observer = new MutationObserver(checkState);
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
    
    checkState();
}

startInitialization();