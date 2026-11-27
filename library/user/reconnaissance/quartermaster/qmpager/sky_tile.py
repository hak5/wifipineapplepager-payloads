"""The ADS-B tile: the aircraft an RTL-SDR stick on the Pager's USB hears, a tile of its own on the Pager's menu."""

from quartermaster import adsb
from quartermaster.ui import icons, screens
from quartermaster.ui.gfx import AMBER, GREEN, MUTED

TILE = ("P", "ADS-B", "plane")
PAGER_WORDS = {adsb.NO_TOOLS: "rtl-sdr is missing. Start Quartermaster again with the stick in to install it",
               adsb.DENIED: "No permission yet. Unplug the stick and plug it in again",
               adsb.DRIVER: "Restart the Pager once to use it"}


def plane(d, s):
    d.polygon([(s * 0.46, s * 0.04), (s * 0.54, s * 0.04), (s * 0.58, s * 0.36), (s * 0.96, s * 0.58),
               (s * 0.96, s * 0.68), (s * 0.58, s * 0.56), (s * 0.56, s * 0.80), (s * 0.70, s * 0.90),
               (s * 0.70, s * 0.97), (s * 0.50, s * 0.91), (s * 0.30, s * 0.97), (s * 0.30, s * 0.90),
               (s * 0.44, s * 0.80), (s * 0.42, s * 0.56), (s * 0.04, s * 0.68), (s * 0.04, s * 0.58),
               (s * 0.42, s * 0.36)], fill=255)


def subtitle(app):
    sky = getattr(app, "sky", None)
    if app.wardriving and app.drive.aircraft is not None:
        status = app.drive.aircraft.status()
        if status["state"] in (adsb.RUNNING, adsb.SYSTEM):
            return "%d aircraft" % status["aircraft"], GREEN
    elif sky is not None:
        return "Listening", GREEN
    if not getattr(app.hw, "sdr", []):
        return "No RTL-SDR", MUTED
    ready, _ = screens.sky_ready(app)
    return ("Ready", MUTED) if ready else ("Check stick", AMBER)


def open_sky(app):
    ready, why = screens.sky_ready(app)
    if not ready:
        app.toast(why or adsb.WORDS[adsb.NO_DONGLE], AMBER, 4)
        return
    from quartermaster.ui.sky_screens import AircraftList
    app.push(AircraftList(app))


def install():
    """Add the ADS-B tile to the end of the Pager's menu."""
    from quartermaster.ui.app import App
    adsb.WORDS.update(PAGER_WORDS)
    icons.ICONS["plane"] = plane
    if TILE not in screens.Home.TILES:
        screens.Home.TILES = screens.Home.TILES + [TILE]
    words = screens.Home.subtitle

    def home_subtitle(self, label, app):
        if label == "ADS-B":
            return subtitle(app)
        return words(self, label, app)
    screens.Home.subtitle = home_subtitle

    opened = App.open

    def open_screen(self, name):
        if name == "ADS-B":
            self.home()
            open_sky(self)
            return
        return opened(self, name)
    App.open = open_screen
