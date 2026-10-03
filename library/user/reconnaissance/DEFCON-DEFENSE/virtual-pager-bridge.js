/* DEFCON Defense Virtual Pager screen bridge.
 *
 * The stock Pager WebSocket shows the firmware-owned canvas. While the custom
 * full-screen application owns the physical framebuffer, this bridge displays
 * the exact same application canvas from its local PNG endpoint, takes control
 * of the six visible Pager buttons, and automatically falls back when the app
 * exits. One in-flight input and one bounded long poll prevent queued presses
 * or a dead request from leaving the browser on the wrong screen.
 */
(() => {
  if (window.__defconDefenseBridgeInstalled) return;
  const accessToken = document.currentScript?.dataset.defconDefenseToken || "";
  if (!accessToken) return;
  window.__defconDefenseBridgeInstalled = true;
  window.__defconDefenseBridgeVersion = "4.4.0";

  const baseEndpoint = `${window.location.protocol}//${window.location.hostname}:1472`;
  const endpoint = `${baseEndpoint}/screen.png`;
  const tokenQuery = `token=${encodeURIComponent(accessToken)}`;
  const pollTimeoutMs = 6500;
  const buttonTimeoutMs = 650;
  let active = false;
  let objectUrl = null;
  let failures = 0;
  let guardedSocket = null;
  let stockSocketHandler = null;
  let etag = "";
  let inFlight = false;
  let pollController = null;
  let pollTimer = null;
  let connectionGeneration = 0;
  let buttonBusy = false;
  let pressedButton = null;
  let pressedImage = null;
  let buttonTimer = null;
  let pendingButton = null;
  let pendingImage = null;

  const buttonNames = {
    "A_BUTTON.PNG": "A",
    "B_BUTTON.PNG": "B",
    "UP.PNG": "UP",
    "DOWN.PNG": "DOWN",
    "LEFT.PNG": "LEFT",
    "RIGHT.PNG": "RIGHT",
  };
  const keyNames = {
    Enter: "A",
    Escape: "B",
    ArrowUp: "UP",
    ArrowDown: "DOWN",
    ArrowLeft: "LEFT",
    ArrowRight: "RIGHT",
  };

  const style = document.createElement("style");
  style.textContent = `
    html.defcon-defense-active body {
      min-height: 100vh !important;
      display: block !important;
      overflow: auto !important;
      background: #121212 !important;
    }
    html.defcon-defense-active #sidebarMobileToggle,
    html.defcon-defense-active #sidebarnav,
    html.defcon-defense-active #header-image,
    html.defcon-defense-active #login,
    html.defcon-defense-active #loading,
    html.defcon-defense-active #payload_portal,
    html.defcon-defense-active #terminalblock {
      display: none !important;
    }
    html.defcon-defense-active main {
      min-height: 100vh !important;
      margin: 0 !important;
      padding: 24px 12px !important;
      display: flex !important;
      align-items: flex-start !important;
      justify-content: center !important;
    }
    html.defcon-defense-active .maincenter {
      width: 100% !important;
      margin: 0 auto !important;
    }
    html.defcon-defense-active #pager_ui {
      display: table !important;
      margin: 0 auto !important;
    }
    html.defcon-defense-active .pager-btn.defcon-button-pending {
      filter: brightness(1.55) drop-shadow(0 0 5px #5de142) !important;
    }
    html.defcon-defense-active .pager-btn:focus {
      outline: none !important;
    }
  `;
  (document.head || document.documentElement).appendChild(style);

  function pagerElement() {
    return document.getElementById("pager");
  }

  function setFocusedMode(enabled) {
    document.documentElement.classList.toggle("defcon-defense-active", enabled);
    if (enabled) {
      const ui = document.getElementById("pager_ui");
      if (ui) ui.hidden = false;
      configureControls();
    }
  }

  function configureControls() {
    document.querySelectorAll("img.pager-btn").forEach((img) => {
      const file = (img.getAttribute("src") || "").split("/").pop().split("?")[0].toUpperCase();
      const button = buttonNames[file];
      if (!button) return;
      img.setAttribute("aria-label", `${button} Pager button`);
      img.setAttribute("alt", `${button} Pager button`);
      img.setAttribute("tabindex", "0");
    });
  }

  function releaseButton(dispatchPending = true) {
    buttonBusy = false;
    if (buttonTimer) clearTimeout(buttonTimer);
    buttonTimer = null;
    if (pressedImage) pressedImage.classList.remove("defcon-button-pending");
    pressedButton = null;
    pressedImage = null;
    const nextButton = dispatchPending && active ? pendingButton : null;
    const nextImage = dispatchPending && active ? pendingImage : null;
    pendingButton = null;
    pendingImage = null;
    if (nextButton) setTimeout(() => void sendButton(nextButton, nextImage), 0);
  }

  async function sendButton(button, img = null) {
    if (!active) return;
    if (buttonBusy) {
      // Preserve one intentional follow-up action (for example LEFT then B)
      // instead of dropping it while the current frame is being acknowledged.
      // Repeated presses of the same held/bounced control remain suppressed.
      if (button !== pressedButton) {
        pendingButton = button;
        pendingImage = img;
      }
      return;
    }
    buttonBusy = true;
    pressedButton = button;
    pressedImage = img;
    if (pressedImage) pressedImage.classList.add("defcon-button-pending");
    buttonTimer = setTimeout(releaseButton, buttonTimeoutMs);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 900);
    try {
      const response = await fetch(`${baseEndpoint}/button?${tokenQuery}&name=${encodeURIComponent(button)}`, {
        method: "POST",
        cache: "no-store",
        signal: controller.signal,
      });
      if (!response.ok) throw new Error("button queue busy");
      scheduleRefresh(0);
    } catch (_) {
      releaseButton(false);
      resetConnection(false);
    } finally {
      clearTimeout(timeout);
    }
  }

  document.addEventListener("click", (event) => {
    if (!active || !(event.target instanceof Element)) return;
    const img = event.target.matches("img")
      ? event.target
      : event.target.closest("button")?.querySelector("img");
    if (!img) return;
    const file = (img.getAttribute("src") || "").split("/").pop().split("?")[0].toUpperCase();
    const button = buttonNames[file];
    if (!button) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    void sendButton(button, img);
  }, true);

  document.addEventListener("keydown", (event) => {
    if (!active || event.ctrlKey || event.metaKey || event.altKey) return;
    const button = keyNames[event.key];
    if (!button) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    void sendButton(button);
  }, true);

  const stockRenderer = window.renderRGBAFrame;
  if (typeof stockRenderer === "function") {
    window.renderRGBAFrame = (bytes) => {
      if (!active) stockRenderer(bytes);
    };
  }

  function guardStockSocket() {
    if (typeof screenws === "undefined" || !screenws || screenws === guardedSocket) return;
    guardedSocket = screenws;
    stockSocketHandler = screenws.onmessage;
    screenws.onmessage = (event) => {
      if (!active && typeof stockSocketHandler === "function") {
        stockSocketHandler.call(screenws, event);
      }
    };
  }

  function scheduleRefresh(delay) {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(refresh, delay);
  }

  function resetConnection(clearRevision = true) {
    connectionGeneration += 1;
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = null;
    if (pollController) pollController.abort();
    pollController = null;
    inFlight = false;
    failures = 0;
    if (clearRevision) etag = "";
    scheduleRefresh(0);
  }

  async function refresh() {
    if (inFlight) return;
    const pager = pagerElement();
    if (!pager) {
      scheduleRefresh(100);
      return;
    }
    guardStockSocket();
    const generation = connectionGeneration;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), pollTimeoutMs);
    pollController = controller;
    inFlight = true;
    try {
      const revision = etag ? `&rev=${encodeURIComponent(etag)}` : "";
      const response = await fetch(`${endpoint}?${tokenQuery}&wait=1${revision}`, {
        cache: "no-store",
        signal: controller.signal,
      });
      if (response.status === 304) {
        active = true;
        failures = 0;
        setFocusedMode(true);
        return;
      }
      if (!response.ok) throw new Error("custom screen unavailable");
      const nextETag = response.headers.get("ETag") || etag;
      const revisionChanged = etag !== "" && nextETag !== etag;
      etag = nextETag;
      const nextUrl = URL.createObjectURL(await response.blob());
      const priorUrl = objectUrl;
      objectUrl = nextUrl;
      active = true;
      failures = 0;
      setFocusedMode(true);
      pager.style.display = "block";
      pager.src = nextUrl;
      if (revisionChanged) releaseButton();
      if (priorUrl) setTimeout(() => URL.revokeObjectURL(priorUrl), 500);
    } catch (error) {
      if (generation !== connectionGeneration) return;
      failures += 1;
      if (failures >= 2) {
        active = false;
        // The native server's frame counter starts over for each payload run.
        // Forget the prior run's ETag before probing for a relaunch; otherwise
        // a new `defcon-1` can look unchanged and leave the stock frame visible
        // until the browser page is manually reloaded.
        etag = "";
        releaseButton(false);
        setFocusedMode(false);
      }
    } finally {
      clearTimeout(timeout);
      if (generation !== connectionGeneration) return;
      pollController = null;
      inFlight = false;
      scheduleRefresh(active ? 0 : 250);
    }
  }

  window.addEventListener("pageshow", () => resetConnection(true));
  window.addEventListener("online", () => resetConnection(true));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") resetConnection(true);
  });

  configureControls();
  refresh();
})();
