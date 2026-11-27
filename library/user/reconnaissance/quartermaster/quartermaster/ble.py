"""Bluetooth scanning through BlueZ over D-Bus. It never connects to or pairs with a device."""

from . import faults
from .wifi import ScanUnavailable


def ble_refusal(name, text=""):
    """A short, fixable reason BlueZ refused to power on or start discovery."""
    name, text = str(name or ""), str(text or "").lower()
    if name.endswith(".Blocked") or "rfkill" in text or "blocked" in text:
        return "Bluetooth is switched off: run  sudo rfkill unblock bluetooth"
    if name.endswith((".AccessDenied", ".NotPermitted", ".NotAuthorized")):
        return "No Bluetooth permission: reboot once after installing"
    if name.endswith(".NotReady"):
        return "Bluetooth adapter is not ready: run  sudo rfkill unblock bluetooth"
    return "Bluetooth refused the scan (%s)" % (name.rsplit(".", 1)[-1] or "unknown")


class BleScanner:
    """BlueZ discovery over D-Bus; one long-lived connection keeps discovery on."""

    name = "BLE"

    def __init__(self):
        self.bus = self.adapter = None
        self.started = False

    def open(self):
        """Connect to BlueZ and start LE discovery. Safe to call again after a refusal."""
        try:
            import dbus
        except ImportError as exc:
            raise ScanUnavailable("BLE needs python3-dbus") from exc
        self.dbus = dbus
        try:
            bus = dbus.SystemBus()
            manager = dbus.Interface(bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager")
            objects = manager.GetManagedObjects()
        except dbus.exceptions.DBusException as exc:
            if "AccessDenied" in str(exc.get_dbus_name()):
                raise ScanUnavailable(ble_refusal(exc.get_dbus_name())) from exc
            raise ScanUnavailable("Bluetooth service (bluetoothd) is not running") from exc
        path = next((p for p, ifaces in objects.items() if "org.bluez.Adapter1" in ifaces), None)
        if path is None:
            raise ScanUnavailable("No Bluetooth adapter found")
        adapter = dbus.Interface(bus.get_object("org.bluez", path), "org.bluez.Adapter1")
        props = dbus.Interface(bus.get_object("org.bluez", path), "org.freedesktop.DBus.Properties")
        try:
            if not props.Get("org.bluez.Adapter1", "Powered"):
                props.Set("org.bluez.Adapter1", "Powered", dbus.Boolean(True))
            adapter.SetDiscoveryFilter({"Transport": dbus.String("le"), "DuplicateData": dbus.Boolean(True)})
            adapter.StartDiscovery()
        except dbus.exceptions.DBusException as exc:
            if "InProgress" not in str(exc.get_dbus_name()):
                raise ScanUnavailable(ble_refusal(exc.get_dbus_name(), str(exc))) from exc
        # Only a fully started scanner is kept, so a refusal (Bluetooth blocked, adapter
        # still powering up) is retried on the next scan instead of silently finding nothing.
        self.bus, self.manager, self.adapter_path, self.adapter = bus, manager, path, adapter
        self.started = True
        return self

    def scan(self):
        if not self.started:
            self.open()
        try:
            objects = self.manager.GetManagedObjects()
        except self.dbus.exceptions.DBusException as exc:
            self.close()
            raise ScanUnavailable("Bluetooth service stopped") from exc
        seen = []
        for path, interfaces in objects.items():
            device = interfaces.get("org.bluez.Device1")
            if not device or not str(path).startswith(str(self.adapter_path)) or "RSSI" not in device:
                continue
            try:
                seen.append(self._record(device))
            except Exception:
                faults.note("Reading a Bluetooth device")
        return seen

    @staticmethod
    def _record(device):
        manufacturer = {int(k): bytes(v) for k, v in device.get("ManufacturerData", {}).items()}
        service_data = {str(k): bytes(v) for k, v in device.get("ServiceData", {}).items()}
        uuids = [str(u) for u in device.get("UUIDs", [])]
        name = str(device.get("Name", "")) if "Name" in device else ""
        return {"address": str(device.get("Address", "")).upper(),
                "address_type": 0 if str(device.get("AddressType", "random")) == "public" else 1,
                "rssi": int(device["RSSI"]), "name": name, "uuids": uuids,
                "manufacturer": manufacturer, "service_data": service_data,
                "tx_power": int(device["TxPower"]) if "TxPower" in device else None,
                "appearance": int(device["Appearance"]) if "Appearance" in device else None,
                "classic": "Class" in device and str(device.get("AddressType", "")) == "public"
                and not device.get("ManufacturerData") and not device.get("ServiceData")}

    def close(self):
        if self.started and self.adapter is not None:
            try:
                self.adapter.StopDiscovery()
            except Exception:
                pass
        self.started = False
        self.bus = self.adapter = None
