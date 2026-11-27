"""Start Quartermaster on the Pager: python3 -m qmpager [--no-splash] [--probe]

The Pager's parts take the place of the CardputerZero's before Quartermaster is loaded: the monitor
radio for Wi-Fi, a raw HCI scan for Bluetooth, the buzzer for tones, and the wide screen and D-pad.
"""

import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import signal
import sys
import threading

LOOT = Path(os.environ.get("QUARTERMASTER_HOME", "/root/loot/quartermaster"))
BUILT_IN = ("wlan0", "wlan1")


def built_in_phys(sys_net="/sys/class/net"):
    phys = set()
    try:
        names = os.listdir(sys_net)
    except OSError:
        return phys
    for name in names:
        if name.startswith(BUILT_IN):
            try:
                with open(os.path.join(sys_net, name, "phy80211", "name")) as f:
                    phys.add(f.read().strip())
            except OSError:
                pass
    return phys


def install():
    """Put the Pager's parts in place. Must run before any other part of Quartermaster is imported."""
    os.environ.setdefault("QUARTERMASTER_HOME", str(LOOT))
    from quartermaster import ble, config, deepscan, flasher, hardware, meshpackets, tones, wigle
    from . import aes, ed25519, hci, listen, sound
    wigle.DISPLAY_SIZES["pager"] = "480x222"
    from .awake import SETTING
    if SETTING not in config.SETTINGS:
        dict(config.SECTIONS)["SCREEN"].append(SETTING)
        config.SETTINGS.append(SETTING)
        config.DEFAULTS[SETTING[0]] = 0
    flasher.DAMAGED = ("Node firmware does not come with the Pager payload. Flash the node from a computer at "
                       "valleytechsolutions.github.io/Quartermaster/flasher, then plug it into the Pager.")
    ble.BleScanner = hci.HciBleScanner
    deepscan.DeepScan = listen.PagerListen
    deepscan.wanted = lambda cfg: True
    tones.Player = sound.BuzzerPlayer
    phys = built_in_phys()
    every = hardware.wifi_adapters

    def usb_adapters(*args, **kwargs):
        return [a for a in every(*args, **kwargs) if a.get("phy") not in phys and a.get("type") != "803"]
    hardware.wifi_adapters = usb_adapters

    found_ports = hardware.gps_candidates

    def gps_ports(*args, **kwargs):
        return [p for p in found_ports(*args, **kwargs) if hardware.port_mark(p["path"]) != "meshtastic"]
    hardware.gps_candidates = gps_ports
    hardware.all_serial_ports = found_ports

    library_ctr, library_verify = meshpackets._aes_ctr, meshpackets._verify

    def aes_ctr(key, nonce, data):
        plain = library_ctr(key, nonce, data)
        return plain if plain is not None else aes.ctr(key, nonce, data)

    def verify(key, message, signature):
        result = library_verify(key, message, signature)
        return result if result is not None else ed25519.verify(key, message, signature)
    meshpackets._aes_ctr, meshpackets._verify = aes_ctr, verify

    from quartermaster import engine
    from quartermaster.ui import screens
    plan = engine.Wardrive._lora_plan

    def lora_plan(self):
        profiles = plan(self)
        if getattr(self.cap, "meshtastic_only", False):
            return [p for p in profiles if p.protocol == "meshtastic"][:1]
        return profiles
    engine.Wardrive._lora_plan = lora_plan
    screens.Hardware.lora_card = staticmethod(lora_card)
    screens.Splash.refresh = 0.1
    from . import biscuit_screen, sky_tile
    biscuit_screen.install()
    sky_tile.install()
    return phys


def lora_card(app, status):
    from quartermaster import lora, mesh
    from quartermaster.ui.screens import AMBER, FAINT, GOLD, GREEN, plural
    cap, on = app.cap, app.cfg.get("lora", "auto")
    live = status.get("lora") if status is not None else None
    title = cap.title() if hasattr(cap, "title") else "USB LoRa radio for mesh nodes"
    card = {"tag": "LORA", "color": GOLD, "title": title, "right": lora.region_name(app.cfg.get("country", "US"))}
    if on is False:
        return dict(card, color=FAINT, detail=mesh.WORDS[lora.OFF], detail_color=FAINT, right="")
    if live is not None and live["state"] == mesh.LISTENING:
        return dict(card, detail=live["detail"], detail_color=GREEN, right=plural(live["packets"], "packet"))
    if live is not None:
        state = live["reason"] or live["state"]
    elif cap.found:
        return dict(card, detail="Ready. It listens in the next wardrive.")
    elif cap.state == lora.ABSENT:
        return dict(card, title="USB LoRa radio", right="", color=FAINT,
                    detail="None plugged in. MeshToad, MeshStick, Glytch Mesh Mod or a Meshtastic board is found "
                           "by itself.", detail_color=FAINT)
    else:
        state = cap.state
    card.update(detail=mesh.WORDS.get(state, mesh.WORDS[mesh.FAILED]), right="")
    if state != lora.CHECKING:
        card.update(color=AMBER, edge=AMBER, detail_color=AMBER)
    return card


def main(argv=None):
    parser = argparse.ArgumentParser(prog="qmpager", description="Quartermaster on the Hak5 WiFi Pineapple Pager")
    parser.add_argument("--no-splash", action="store_true")
    parser.add_argument("--probe", action="store_true")
    args = parser.parse_args(argv)
    os.umask(0o077)
    install()
    from quartermaster import config, faults, hardware, lora, wigle
    from quartermaster.engine import DEFAULT_ROOT
    from quartermaster.power import Rails
    from quartermaster.ui.app import App, HardwareWatch
    from . import biscuit, listen, updates, usblora, wide
    from .buttons import PagerInput
    from .awake import ScreenKeeper
    from .device import Backlight, Lights
    from .gps import PagerGPS
    from .screen import PagerDisplay
    from .sound import BuzzerPlayer

    gps_ports = lambda: hardware.gps_candidates(cardputer=False)  # noqa: E731
    if args.probe:
        print("monitor  %s  %s" % (listen.INTERFACE, "found" if listen.present() else "missing"))
        for adapter in hardware.wifi_adapters():
            print("wifi  %(interface)s  %(label)s  bands=%(bands)s  usb=%(usb_id)s" % adapter)
        for port in gps_ports():
            print("gps   %(path)s  %(label)s" % port)
        radio = usblora.UsbLora(ports=lambda: hardware.all_serial_ports(cardputer=False))
        radio.look()
        print("lora  %s" % (radio.title() if radio.found else lora.WORDS.get(radio.state, radio.state)))
        return 0

    DEFAULT_ROOT.mkdir(parents=True, exist_ok=True)
    faults.path = DEFAULT_ROOT / "errors.log"
    cfg = config.load()
    cfg.setdefault("country_set", True)
    lights = Lights()
    with ExitStack() as cleanup:
        try:
            display = PagerDisplay()
            cleanup.callback(display.close)
            keyboard = PagerInput()
            cleanup.callback(keyboard.close)
        except (OSError, ImportError) as exc:
            print("Cannot open the Pager screen or buttons: %s" % exc, file=sys.stderr)
            return 2
        cleanup.callback(lights.off)
        rails = Rails(())
        gps = PagerGPS(cfg.get("gps_source", "auto"), candidates=gps_ports, rails=rails, power=False)
        stopped = threading.Event()
        worker = threading.Thread(target=gps.run, args=(stopped,), daemon=True, name="gps")
        worker.start()
        cleanup.callback(worker.join, 3)
        cleanup.callback(stopped.set)
        cap = usblora.UsbLora(ports=lambda: hardware.all_serial_ports(cardputer=False))
        cleanup.callback(cap.stop)
        app = App(display, keyboard, gps, cfg, root=DEFAULT_ROOT, splash=not args.no_splash,
                  hw=HardwareWatch(gps_ports=gps_ports), cap=cap,
                  updates=updates.check_pager)
        app.square = wide.WideUI()
        app.biscuit = biscuit.BiscuitLink()
        cleanup.callback(app.biscuit.stop, True)
        if isinstance(app.player, BuzzerPlayer):
            app.player.vibrate = lambda: app.cfg.get("drive_alert_tones", True)
        wigle.prune_empty(app.logs_dir)

        def stop(*_):
            app.running = False
        keyboard.on_quit = stop
        keeper = ScreenKeeper(Backlight(), lambda: app.cfg.get("screen_timeout", 0))
        keyboard.on_input = keeper.touch
        lit = threading.Thread(target=keeper.run, args=(stopped,), daemon=True, name="screen")
        lit.start()
        cleanup.callback(keeper.restore)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, stop)
        app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
