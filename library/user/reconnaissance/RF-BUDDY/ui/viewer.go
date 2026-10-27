package main

// viewerHTML is RF-BUDDY's own remote viewer, served on the Virtual listen
// port. It is self-contained: no external scripts, fonts, or images.
const viewerHTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RF-BUDDY</title>
<style>
  body { margin: 0; padding: 8px; background: #111; color: #eee; font-family: sans-serif; text-align: center; }
  #screen { display: block; margin: 0 auto 12px; width: 100%; max-width: 960px; height: auto; image-rendering: pixelated; background: #000; }
  .row { display: flex; justify-content: center; gap: 8px; margin-bottom: 8px; }
  button { min-width: 72px; min-height: 48px; font-size: 16px; font-weight: bold; border: 0; border-radius: 6px; background: #444; color: #fff; }
  button:active { background: #666; }
  #B { background: #c0392b; }
  #A { background: #27ae60; }
</style>
</head>
<body>
<img id="screen" alt="RF-BUDDY screen">
<div class="row"><button id="LEFT">LEFT</button><button id="UP">UP</button><button id="DOWN">DOWN</button><button id="RIGHT">RIGHT</button></div>
<div class="row"><button id="B">B</button><button id="A">A</button></div>
<script>
(function () {
  var img = document.getElementById("screen");
  var etag = "";
  var prev = "";
  async function poll() {
    for (;;) {
      try {
        var r = await fetch("/screen.png?wait=1&rev=" + encodeURIComponent(etag), { cache: "no-store" });
        if (r.status === 200) {
          etag = r.headers.get("ETag") || "";
          var url = URL.createObjectURL(await r.blob());
          img.src = url;
          if (prev) URL.revokeObjectURL(prev);
          prev = url;
        } else if (r.status !== 304) {
          await new Promise(function (ok) { setTimeout(ok, 1000); });
        }
      } catch (e) {
        await new Promise(function (ok) { setTimeout(ok, 1000); });
      }
    }
  }
  function press(name) {
    fetch("/button?name=" + name, { method: "POST", headers: { "X-RF-Buddy": "1" } }).catch(function () {});
  }
  ["LEFT", "UP", "DOWN", "RIGHT", "B", "A"].forEach(function (n) {
    document.getElementById(n).addEventListener("click", function () { press(n); });
  });
  var keys = { ArrowUp: "UP", ArrowDown: "DOWN", ArrowLeft: "LEFT", ArrowRight: "RIGHT", Enter: "A", Escape: "B", Backspace: "B" };
  document.addEventListener("keydown", function (e) {
    var n = keys[e.key];
    if (n) { e.preventDefault(); press(n); }
  });
  poll();
})();
</script>
</body>
</html>
`
