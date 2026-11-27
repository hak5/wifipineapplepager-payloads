"""The Biscuit tile: run the Pager as the 6 GHz node of a Biscuit or Biscuit Pro.

As with CodeHedge's Biscuit Pager Node payload, there is no pairing here: start node mode, then search for nodes in
the Biscuit Manager app. The Pager shows up there as a Pager node and the Biscuit adds it.
"""

from quartermaster.ui import icons, screens
from quartermaster.ui.gfx import AMBER, GOLD, GREEN, MUTED, RED

from . import biscuit

TILE = ("B", "Biscuit", "biscuit")
WORDS = {
    biscuit.STARTING: ("Starting", "Taking the Pager radio from PineAP.", GOLD),
    biscuit.SEARCHING: ("Waiting", "Search for nodes in the Biscuit Manager app. This Pager shows up as a Pager "
                                   "node: add it there.", AMBER),
    biscuit.JOINED: ("Joined", "Joined. Start a wardrive on the Biscuit and this Pager scans 6 GHz for it.", GOLD),
    biscuit.SCANNING: ("Scanning", "Scanning 6 GHz for the Biscuit.", GREEN),
    biscuit.SECURE: ("Secure mode", "The Biscuit is in Secure node mode. Set it to Extended node mode.", RED),
    biscuit.OLD: ("Old firmware", "This Biscuit's firmware takes no 6 GHz nodes. Update the Biscuit.", AMBER),
    biscuit.STOPPING: ("Stopping", "Giving the Pager radio back to PineAP.", GOLD),
    biscuit.FAILED: ("Stopped", "Node mode stopped.", RED),
    biscuit.OFF: ("Off", "", MUTED),
}
BUSY = "Stop the wardrive and Recon first: node mode scans 6 GHz and nothing else."
HELP = ("Set your Biscuit or Biscuit Pro to Extended node mode and press green. Then search for nodes in the Biscuit "
        "Manager app: this Pager shows up as a Pager node and the Biscuit adds it. It scans 6 GHz only.")


def cookie(d, s):
    d.ellipse((s * 0.06, s * 0.06, s * 0.94, s * 0.94), fill=255)
    for x, y in ((0.34, 0.32), (0.62, 0.30), (0.48, 0.52), (0.30, 0.66), (0.66, 0.66)):
        d.ellipse((s * (x - 0.07), s * (y - 0.07), s * (x + 0.07), s * (y + 0.07)), fill=0)


class BiscuitScreen(screens.Screen):
    title = "Biscuit node"
    refresh = 0.5

    def hints(self, app):
        return [("OK", "Stop node")] if app.biscuit.running else [("OK", "Start node")]

    def busy(self, app):
        if app.wardriving or app.recon_running:
            app.toast(BUSY, AMBER, 4)
            return True
        return False

    def tick(self, app):
        pass

    def handle(self, key, app):
        link = app.biscuit
        name = key.name
        if name == "ENTER" and not key.repeat:
            if link.running:
                link.stop()
            elif not self.busy(app):
                link.start()
            return True
        if name in ("ESC", "BACKSPACE"):
            app.pop()
            return True
        return False

    def render(self, c, app):
        pass


def subtitle(app):
    link = app.biscuit
    if link.running:
        word, _, color = WORDS.get(link.state, WORDS[biscuit.FAILED])
        return word, color
    if link.state == biscuit.FAILED:
        return "Stopped", AMBER
    return "Off", MUTED


def install():
    """Add the Biscuit tile to the Pager's menu and keep node mode, wardrives and Recon from running together."""
    from quartermaster.ui.app import App
    icons.ICONS["biscuit"] = cookie
    if TILE not in screens.Home.TILES:
        screens.Home.TILES = screens.Home.TILES[:2] + [TILE] + screens.Home.TILES[2:]
    words = screens.Home.subtitle

    def home_subtitle(self, label, app):
        if label == "Biscuit" and getattr(app, "biscuit", None) is not None:
            return subtitle(app)
        return words(self, label, app)
    screens.Home.subtitle = home_subtitle

    opened = App.open

    def open_screen(self, name):
        if name == "Biscuit":
            self.home()
            self.push(BiscuitScreen())
            return
        return opened(self, name)
    App.open = open_screen

    def guarded(method):
        def run(self, *args, **kwargs):
            link = getattr(self, "biscuit", None)
            if link is not None and link.running:
                self.toast("Biscuit node mode is on. Stop it on the Biscuit tile first.", AMBER, 4)
                return False
            return method(self, *args, **kwargs)
        return run
    App.start_wardrive = guarded(App.start_wardrive)
    App.start_recon = guarded(App.start_recon)
