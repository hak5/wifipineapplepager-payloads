"""Entry point: `python3 -m quartermaster`, installed as /usr/share/APPLaunch/bin/quartermaster."""

import argparse
from contextlib import ExitStack
from functools import partial
import os
import signal
import sys
import tempfile
import threading


def main(argv=None):
    parser = argparse.ArgumentParser(prog="quartermaster", description="Quartermaster wardriver")
    parser.add_argument("--display", choices=("cardputer", "st7735-128", "st7789-240"), default="cardputer",
                        help="CardputerZero framebuffer or Waveshare 1.44-inch / 1.3-inch LCD HAT")
    parser.add_argument("--no-splash", action="store_true", help="skip the boot animation")
    parser.add_argument("--probe", action="store_true", help="print the adapters and GPS ports found, then exit")
    parser.add_argument("--version", action="store_true", help="print the version, then exit")
    args = parser.parse_args(argv)
    os.umask(0o077)

    from . import __version__, config, hardware, lora
    if args.version:
        print(__version__)
        return 0
    cardputer = args.display == "cardputer"
    gps_ports = partial(hardware.gps_candidates, cardputer=cardputer)
    if args.probe:
        print("display  %s" % args.display)
        for adapter in hardware.wifi_adapters():
            print("wifi  %(interface)s  %(label)s  bands=%(bands)s  usb=%(usb_id)s  driver=%(driver)s" % adapter)
        for adapter in hardware.stalled_usb_adapters():
            title, detail = hardware.stall_words(hardware.explain(adapter))
            print("wifi  (not starting)  %s  usb=%s  port=%s  %s" % (title, adapter["usb_id"], adapter["port"], detail))
        for port in gps_ports():
            print("gps   %(path)s  %(label)s" % port)
        if cardputer:
            cap = lora.Cap()
            cap.start()
            cap.wait(10)
            print("lora  Cap LoRa-1262: %s" % ("found" if cap.found else lora.WORDS.get(cap.state, cap.state)))
        return 0

    from . import faults, updates_check, wigle
    from .engine import DEFAULT_ROOT
    from .gnss import GPS
    from .power import Rails
    from .ui.app import App, HardwareWatch
    from .ui.display import FramebufferDisplay
    from .ui.keys import EvdevInput

    faults.path = DEFAULT_ROOT / "errors.log"
    cfg = config.load()
    if not cardputer and cfg.get("gps_source") == "/dev/ttyS0":
        cfg["gps_source"] = "auto"  # A setting carried over from a Cardputer's Cap / Grove connector.
    with ExitStack() as cleanup:
        try:
            if cardputer:
                display = FramebufferDisplay()
                cleanup.callback(display.close)
                keyboard = EvdevInput()
            else:
                # lgpio opens a notification FIFO relative to its working directory at import.
                # Keep the pipe private, then return to the caller's directory before opening logs.
                gpio_dir = cleanup.enter_context(tempfile.TemporaryDirectory(prefix="quartermaster-gpio-"))
                with ExitStack() as startup:
                    startup.callback(os.chdir, os.getcwd())
                    os.chdir(gpio_dir)
                    if "LG_WD" in os.environ:
                        startup.callback(os.environ.__setitem__, "LG_WD", os.environ.pop("LG_WD"))
                    from .ui.hat import HatDisplay, HatInput
                    display = HatDisplay(args.display)
                    cleanup.callback(display.close)
                    keyboard = HatInput()
            cleanup.callback(keyboard.close)
        except (OSError, ImportError) as exc:
            print("Cannot open %s display or controls: %s" % (args.display, exc), file=sys.stderr)
            return 2

        rails = Rails() if cardputer else Rails(())
        cleanup.callback(rails.restore_all)
        gps = GPS(cfg.get("gps_source", "auto"), candidates=gps_ports, rails=rails, power=cfg.get("gps_power", True))
        stopped = threading.Event()
        worker = threading.Thread(target=gps.run, args=(stopped,), daemon=True, name="gps")
        worker.start()
        cleanup.callback(worker.join, 3)
        cleanup.callback(stopped.set)
        app = App(display, keyboard, gps, cfg, root=DEFAULT_ROOT, splash=not args.no_splash,
                  hw=HardwareWatch(gps_ports=gps_ports), cap=lora.Cap(rails, cardputer=cardputer),
                  updates=updates_check.check if cardputer else updates_check.check_pi)
        wigle.prune_empty(app.logs_dir)

        def stop(*_):
            app.running = False
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, stop)
        app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
