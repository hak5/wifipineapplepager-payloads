"""The setup page: paste upload keys from a phone or PC on the same network.

The page is served only while the Cardputer shows the setup screen, and only
after the PIN from that screen is entered. Of a saved key only the last four
characters are sent back to the browser.
"""

import hmac
import html
from http import cookies
import http.server
import json
from pathlib import Path
import re
import secrets
import threading
import urllib.parse

from . import __version__, accounts as keys, uploads, wigle

PORT = 8642
MAX_BODY = 32 * 1024
MAX_WRONG_PINS = 5
LOG_NAME = re.compile(r"quartermaster_[0-9]{8}-[0-9]{6}(-[0-9]+)?\.(wigle|summary)\.csv")
HINTS = {
    "wigle": "On wigle.net open Account, then Show My Token. Paste the API Name and API Token, "
             "or only the Encoded for use line.",
    "wdgwars": "On wdgwars.pl open your Profile and press Generate API key.",
    "wardrift": "On wardrift.net open the Dashboard, then API Keys, and create a key for a wardriving device.",
}
SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
                               "connect-src 'self'; form-action 'self'; base-uri 'none'",
}

STYLE = """
*{box-sizing:border-box}body{margin:0;background:#06070a;color:#eaf1ed;font:16px/1.45 system-ui,sans-serif}
main{max-width:560px;margin:0 auto;padding:20px 16px 48px}
h1{margin:0;color:#f5b301;letter-spacing:.12em;font-size:22px}
.sub{margin:2px 0 18px;color:#88998f;font-size:13px}
section,form.card{background:#0d1317;border:1px solid #202d34;border-radius:12px;padding:14px;margin:0 0 14px}
h2{margin:0 0 4px;font-size:17px;color:#f5b301}
.hint{margin:0 0 10px;color:#88998f;font-size:13px}
label{display:block;margin:8px 0 0;font-size:13px;color:#b8c6bf}
input,textarea{width:100%;margin-top:4px;padding:10px;border-radius:8px;border:1px solid #2b3a42;background:#04070a;
color:#eaf1ed;font:15px ui-monospace,monospace}
textarea{min-height:96px}
button{margin-top:10px;padding:10px 16px;border-radius:8px;border:1px solid #2b3a42;background:#141d23;
color:#eaf1ed;font:600 15px system-ui,sans-serif}
button.primary{background:#f5b301;border-color:#f5b301;color:#1a1200;width:100%}
button.link{border:0;background:none;color:#88998f;padding:10px 4px;text-decoration:underline}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.note{font-size:13px;color:#88998f}.ok{color:#4dff4d}.bad{color:#ff5454}
.banner{background:#12300f;border:1px solid #2c6b27;color:#b6ffb0;border-radius:10px;padding:10px 12px;margin:0 0 14px}
.banner.bad{background:#3a1012;border-color:#7a2226;color:#ffc2c2}
table{width:100%;border-collapse:collapse;font-size:13px}td{padding:6px 4px;border-top:1px solid #202d34}
a{color:#f5b301}.pin{font-size:28px;letter-spacing:.3em;text-align:center}
"""

SCRIPT = """
const csrf = %s;
async function send(path, data) {
  const body = new URLSearchParams(Object.assign({csrf: csrf}, data));
  const reply = await fetch(path, {method: "POST", body: body, credentials: "same-origin"});
  return reply.json();
}
document.querySelectorAll("[data-test]").forEach(function (button) {
  button.addEventListener("click", async function () {
    const service = button.dataset.test, note = document.getElementById("result-" + service);
    const data = {service: service};
    button.closest("section").querySelectorAll("input").forEach(function (field) {
      if (field.value.trim()) { data[field.name] = field.value.trim(); }
    });
    note.textContent = "Checking...";
    note.className = "note";
    try {
      const result = await send("/test", data);
      note.textContent = result.detail;
      note.className = "note " + (result.ok ? "ok" : "bad");
    } catch (error) {
      note.textContent = "Could not reach the Cardputer. Is the setup screen still open?";
      note.className = "note bad";
    }
  });
});
"""

UNLOCK_SCRIPT = """
const match = location.hash.match(/^#([0-9]{6})$/);
if (match) {
  document.getElementById("pin").value = match[1];
  history.replaceState(null, "", "/");
  document.forms[0].submit();
}
"""


def _same(a, b):
    return hmac.compare_digest(str(a).encode("utf-8"), str(b).encode("utf-8"))


def _page(title, body, script=""):
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<title>%s</title><style>%s</style></head><body><main><h1>QUARTERMASTER</h1>"
            "<p class=\"sub\">Setup page, version %s</p>%s</main>%s</body></html>"
            % (html.escape(title), STYLE, html.escape(__version__), body,
               "<script>%s</script>" % script if script else "")).encode("utf-8")


class SetupServer:
    def __init__(self, logs_dir, cfg=None, accounts_path=None, port=PORT, on_keys=None, on_ignore=None,
                 on_upload=None, tester=uploads.test, marks=None, host="0.0.0.0"):
        self.logs_dir = Path(logs_dir)
        self.cfg = cfg if cfg is not None else {}
        self.accounts_path = accounts_path
        self.port, self.host = port, host
        self.on_keys, self.on_ignore, self.on_upload = on_keys, on_ignore, on_upload
        self.tester, self.marks = tester, marks
        self.pin = "%06d" % secrets.randbelow(1000000)
        self.token = secrets.token_urlsafe(24)
        self.csrf = secrets.token_urlsafe(24)
        self.wrong_pins = 0
        self.visits = 0
        self.saves = 0
        self.server = None
        self.lock = threading.Lock()

    @property
    def locked(self):
        return self.wrong_pins >= MAX_WRONG_PINS

    def start(self):
        handler = _handler(self)
        for port in (self.port, 0):
            try:
                self.server = http.server.ThreadingHTTPServer((self.host, port), handler)
                break
            except OSError:
                if port == 0:
                    raise
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True, name="setup-page").start()
        return self

    def stop(self):
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None

    def unlock_page(self, wrong=False):
        if self.locked:
            body = ("<div class=\"banner bad\">Too many wrong PINs. Close the setup screen on the Cardputer and "
                    "open it again for a new PIN.</div>")
            return _page("Quartermaster setup", body)
        body = ("%s<form class=\"card\" method=\"post\" action=\"/unlock\"><h2>Enter the PIN</h2>"
                "<p class=\"hint\">It is on the Cardputer screen right now.</p>"
                "<input class=\"pin\" id=\"pin\" name=\"pin\" inputmode=\"numeric\" maxlength=\"6\" "
                "autocomplete=\"off\" autofocus><button class=\"primary\">Open setup</button></form>"
                % ("<div class=\"banner bad\">That PIN is not right.</div>" if wrong else ""))
        return _page("Quartermaster setup", body, UNLOCK_SCRIPT)

    def main_page(self, notice=""):
        accounts = keys.load(self.accounts_path)
        hidden = "<input type=\"hidden\" name=\"csrf\" value=\"%s\">" % html.escape(self.csrf)

        def field(name, label, secret=True):
            saved = keys.masked(accounts.get(name, ""))
            return ("<label>%s<input name=\"%s\" type=\"%s\" placeholder=\"%s\" autocomplete=\"off\" "
                    "autocapitalize=\"none\" spellcheck=\"false\" maxlength=\"%d\"></label>"
                    % (html.escape(label), name, "password" if secret else "text",
                       html.escape("Saved: " + saved if saved else "Not set"), keys.MAX_LENGTH))

        def site(service, fields):
            state = "Key saved" if keys.configured(accounts, service) else "No key yet"
            return ("<section><h2>%s</h2><p class=\"hint\">%s</p>%s<div class=\"row\">"
                    "<button type=\"button\" data-test=\"%s\">Save and test</button>"
                    "<span class=\"note\" id=\"result-%s\">%s</span></div></section>"
                    % (keys.SERVICE_NAMES[service], html.escape(HINTS[service]), fields, service, service, state))

        parts = []
        if notice:
            parts.append("<div class=\"banner\">%s</div>" % html.escape(notice))
        parts.append("<form method=\"post\" action=\"/save\">%s%s%s%s"
                     "<button class=\"primary\">Save keys</button>"
                     "<p class=\"hint\">Leave a box empty to keep the key that is already saved.</p></form>"
                     % (hidden,
                        site("wigle", field("wigle_name", "API name", False) + field("wigle_token", "API token")
                             + field("wigle_encoded", "or Encoded for use")),
                        site("wdgwars", field("wdgwars_key", "API key")),
                        site("wardrift", field("wardrift_key", "API key"))))
        ignore = "\n".join(self.cfg.get("ignore", ()))
        parts.append("<form class=\"card\" method=\"post\" action=\"/ignore\">%s<h2>Networks to leave out</h2>"
                     "<p class=\"hint\">One Wi-Fi name or MAC address per line, such as your home network or "
                     "phone hotspot. They still show on the screen but are never logged or uploaded.</p>"
                     "<textarea name=\"ignore\" spellcheck=\"false\">%s</textarea><button>Save list</button></form>"
                     % (hidden, html.escape(ignore)))
        rows = []
        logs = [p for p in sorted(self.logs_dir.glob(wigle.LOG_GLOB), reverse=True) if LOG_NAME.fullmatch(p.name)]
        for path in logs[:60]:
            marks = self.marks(path.name) if self.marks else {}
            sent = ", ".join(keys.SERVICE_NAMES[s] for s, m in marks.items() if m == "done") or "not sent yet"
            summary = path.name.replace(".wigle.csv", ".summary.csv")
            extra = " · <a href=\"/log/%s\">summary</a>" % summary if (self.logs_dir / summary).exists() else ""
            rows.append("<tr><td><a href=\"/log/%s\">%s</a>%s</td><td>%d KB</td><td>%s</td></tr>"
                        % (path.name, path.name[14:29], extra, max(1, path.stat().st_size // 1024),
                           html.escape(sent)))
        parts.append("<section><h2>Logs</h2><p class=\"hint\">Tap a log to download it. Times are UTC.</p>"
                     "<table>%s</table><form method=\"post\" action=\"/upload\">%s<button>Upload now</button>"
                     "</form></section>" % ("".join(rows) or "<tr><td>No wardrives saved yet</td></tr>", hidden))
        for service in keys.SERVICES:
            if keys.configured(accounts, service):
                parts.append("<form method=\"post\" action=\"/remove\">%s<input type=\"hidden\" name=\"service\" "
                             "value=\"%s\"><button class=\"link\">Remove the %s key</button></form>"
                             % (hidden, service, keys.SERVICE_NAMES[service]))
        return _page("Quartermaster setup", "".join(parts), SCRIPT % json.dumps(self.csrf))

    def save_keys(self, form):
        changes = {name: form[name] for name in ("wigle_name", "wigle_token", "wigle_encoded", "wdgwars_key",
                                                 "wardrift_key") if keys.clean(form.get(name))}
        if not changes:
            return False
        with self.lock:
            keys.update(changes, self.accounts_path)
            self.saves += 1
        if self.on_keys:
            self.on_keys()
        return True

    def remove_key(self, service):
        if service not in keys.SERVICES:
            return
        with self.lock:
            keys.update({field: "" for field in keys.SERVICES[service]}, self.accounts_path)
            self.saves += 1
        if self.on_keys:
            self.on_keys()

    def save_ignore(self, text):
        from .config import MAX_IGNORED
        items = []
        for line in text.replace("\r", "").split("\n"):
            line = line.strip()[:64]
            if line and line not in items:
                items.append(line)
        self.cfg["ignore"] = items[:MAX_IGNORED]
        if self.on_ignore:
            self.on_ignore(self.cfg["ignore"])


def _handler(setup):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "Quartermaster"
        sys_version = ""
        timeout = 15

        def log_message(self, *args):
            pass

        def authorised(self):
            jar = cookies.SimpleCookie()
            try:
                jar.load(self.headers.get("Cookie", ""))
            except cookies.CookieError:
                return False
            return "qm" in jar and _same(jar["qm"].value, setup.token)

        def reply(self, status, body, content_type="text/html; charset=utf-8", extra=None):
            self.send_response(status)
            for name, value in dict(SECURITY_HEADERS, **(extra or {})).items():
                self.send_header(name, value)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def redirect(self, where, extra=None):
            self.reply(303, b"", extra=dict({"Location": where}, **(extra or {})))

        def form(self):
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return None
            if not 0 <= length <= MAX_BODY:
                return None
            raw = self.rfile.read(length).decode("utf-8", "replace")
            return {name: values[0] for name, values in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}

        def do_GET(self):
            setup.visits += 1
            path = urllib.parse.urlsplit(self.path)
            if not self.authorised():
                return self.reply(200, setup.unlock_page())
            if path.path == "/":
                notice = {"keys": "Keys saved.", "list": "List saved.", "upload": "Upload started.",
                          "removed": "Key removed.", "nothing": "Nothing to save: the boxes were empty."}
                return self.reply(200, setup.main_page(notice.get(path.query, "")))
            if path.path.startswith("/log/"):
                name = path.path[5:]
                target = setup.logs_dir / name
                if LOG_NAME.fullmatch(name) and target.is_file():
                    data = target.read_bytes()
                    return self.reply(200, data, "text/csv; charset=utf-8",
                                      {"Content-Disposition": "attachment; filename=\"%s\"" % name})
            self.reply(404, _page("Not found", "<div class=\"banner bad\">Nothing here.</div>"))

        def do_POST(self):
            form = self.form()
            if form is None:
                return self.reply(413, b"")
            if self.path == "/unlock":
                if setup.locked:
                    return self.reply(429, setup.unlock_page())
                if _same(form.get("pin", "").strip(), setup.pin):
                    setup.wrong_pins = 0
                    cookie = "qm=%s; HttpOnly; SameSite=Strict; Path=/" % setup.token
                    return self.redirect("/", {"Set-Cookie": cookie})
                setup.wrong_pins += 1
                return self.reply(403, setup.unlock_page(wrong=True))
            if not self.authorised() or not _same(form.get("csrf", ""), setup.csrf):
                return self.reply(403, setup.unlock_page())
            if self.path == "/save":
                return self.redirect("/?keys" if setup.save_keys(form) else "/?nothing")
            if self.path == "/remove":
                setup.remove_key(form.get("service", ""))
                return self.redirect("/?removed")
            if self.path == "/ignore":
                setup.save_ignore(form.get("ignore", ""))
                return self.redirect("/?list")
            if self.path == "/upload":
                if setup.on_upload:
                    setup.on_upload()
                return self.redirect("/?upload")
            if self.path == "/test":
                service = form.get("service", "")
                if service not in keys.SERVICES:
                    return self.reply(400, b"{}", "application/json")
                setup.save_keys(form)
                outcome = setup.tester(service, keys.load(setup.accounts_path))
                body = json.dumps({"ok": outcome.state == uploads.DONE, "detail": outcome.detail})
                return self.reply(200, body.encode("utf-8"), "application/json")
            self.reply(404, b"")

    return Handler
