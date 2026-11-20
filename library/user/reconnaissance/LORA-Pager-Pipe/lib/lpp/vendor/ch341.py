from __future__ import annotations

import errno
import logging
import threading
import time
from enum import IntEnum
from typing import Optional

logger = logging.getLogger(__name__)

try:
    import usb.core
    import usb.util
except Exception as e:  # pragma: no cover
    raise ImportError("PyUSB is required for CH341 support. Install with: pip install pyusb") from e


class CH341Error(Exception):
    """CH341 device error."""


class CH341SPIError(CH341Error):
    """CH341 SPI operation error."""


class TransferState(IntEnum):
    """Sentinel values used by the previous implementation (kept for compatibility)."""

    IDLE = 0
    ACTIVE = -2
    ERROR = -1


class CH341Async:
    """CH341 USB device.

    Multiple adapters may be open at once. Instances are keyed by
    (vid, pid, bus, address, serial_number). Legacy single-adapter callers that
    omit location filters still work when exactly one matching device is present.

    Despite the name, current operations are synchronous bulk transfers.
    """

    # Registry of open devices: identity_key -> instance
    _instances: dict = {}
    # Backward-compat alias for the most recently created/opened instance.
    _instance = None

    # Device IDs
    DEFAULT_VID = 0x1A86
    DEFAULT_PID = 0x5512

    # Endpoints
    EP_OUT = 0x02
    EP_IN = 0x82

    # Commands
    CMD_SPI_STREAM = 0xA8
    CMD_UIO_STREAM = 0xAB
    CMD_UIO_READ = 0xA0
    CMD_UIO_STM_OUT = 0x80
    CMD_UIO_STM_DIR = 0x40
    CMD_UIO_STM_END = 0x20

    # Packet constraints
    CH341_PACKET_LENGTH = 0x20  # 32 bytes
    MAX_PAYLOAD = 0x1F  # 31 bytes

    # Timeout
    USB_TIMEOUT = 5000  # ms

    @staticmethod
    def _identity_key(
        vid: int,
        pid: int,
        bus: Optional[int] = None,
        address: Optional[int] = None,
        serial_number: Optional[str] = None,
    ) -> tuple:
        sn = (serial_number or "").strip() or None
        return (int(vid), int(pid), bus, address, sn)

    @staticmethod
    def _device_serial(dev) -> Optional[str]:
        try:
            sn = usb.util.get_string(dev, dev.iSerialNumber)
            if sn:
                return str(sn).strip() or None
        except Exception:
            pass
        return None

    @classmethod
    def list_devices(cls, vid: int = DEFAULT_VID, pid: int = DEFAULT_PID) -> list[dict]:
        """Return matching CH341 USB devices with location metadata."""
        found = []
        try:
            devices = list(usb.core.find(find_all=True, idVendor=vid, idProduct=pid) or [])
        except Exception as e:
            raise CH341Error(f"USB enumeration failed: {e}") from e
        for dev in devices:
            entry = {
                "vid": int(getattr(dev, "idVendor", vid) or vid),
                "pid": int(getattr(dev, "idProduct", pid) or pid),
                "bus": getattr(dev, "bus", None),
                "address": getattr(dev, "address", None),
                "serial_number": cls._device_serial(dev),
            }
            found.append(entry)
        return found

    @classmethod
    def _find_device(
        cls,
        vid: int,
        pid: int,
        bus: Optional[int] = None,
        address: Optional[int] = None,
        serial_number: Optional[str] = None,
    ):
        """Select one usb.core.Device using optional location filters."""
        try:
            devices = list(usb.core.find(find_all=True, idVendor=vid, idProduct=pid) or [])
        except Exception as e:
            raise CH341Error(f"USB enumeration failed: {e}") from e

        sn_filter = (serial_number or "").strip() or None
        matched = []
        for dev in devices:
            if bus is not None and getattr(dev, "bus", None) != bus:
                continue
            if address is not None and getattr(dev, "address", None) != address:
                continue
            if sn_filter is not None:
                dev_sn = cls._device_serial(dev)
                if dev_sn != sn_filter:
                    continue
            matched.append(dev)

        if not matched:
            filters = [f"VID={vid:04x}", f"PID={pid:04x}"]
            if bus is not None:
                filters.append(f"bus={bus}")
            if address is not None:
                filters.append(f"address={address}")
            if sn_filter is not None:
                filters.append(f"serial={sn_filter!r}")
            available = cls.list_devices(vid=vid, pid=pid)
            avail_txt = (
                ", ".join(
                    f"bus={d.get('bus')} addr={d.get('address')} serial={d.get('serial_number')!r}"
                    for d in available
                )
                or "(none)"
            )
            raise CH341Error(
                "CH341 device not found with filters "
                + ", ".join(filters)
                + f". Available matching VID/PID: {avail_txt}"
            )

        if len(matched) > 1 and bus is None and address is None and sn_filter is None:
            # Ambiguous: multiple adapters, no selector.
            details = []
            for d in matched:
                details.append(
                    f"bus={getattr(d, 'bus', None)} "
                    f"address={getattr(d, 'address', None)} "
                    f"serial={cls._device_serial(d)!r}"
                )
            raise CH341Error(
                "Multiple CH341 devices found; specify ch341.bus + ch341.address "
                "and/or ch341.serial_number to select one. Found: " + "; ".join(details)
            )

        return matched[0]

    def __new__(
        cls,
        vid: int = DEFAULT_VID,
        pid: int = DEFAULT_PID,
        bus: Optional[int] = None,
        address: Optional[int] = None,
        serial_number: Optional[str] = None,
    ):
        # Defer registry key until device is resolved in __init__ when filters
        # are incomplete (single-device auto-pick). Always create a fresh shell;
        # __init__ reuses/returns via get_instance for the public API.
        inst = super().__new__(cls)
        inst._initialized = False
        return inst

    def __init__(
        self,
        vid: int = DEFAULT_VID,
        pid: int = DEFAULT_PID,
        bus: Optional[int] = None,
        address: Optional[int] = None,
        serial_number: Optional[str] = None,
    ):
        if getattr(self, "_initialized", False):
            return

        self.vid = int(vid)
        self.pid = int(pid)
        self.bus = bus
        self.address = address
        self.serial_number = (serial_number or "").strip() or None

        self.dev: Optional[usb.core.Device] = None
        self._ep_out = None
        self._ep_in = None
        self._registry_key = None

        # GPIO shadow state
        self.gpio_state = 0x3F  # All HIGH
        self.gpio_dir = 0x3F  # All outputs

        # Thread safety
        self._transfer_lock = threading.Lock()
        self._operation_lock = threading.RLock()

        self._open_device()
        self._initialized = True

        # Register under resolved identity (includes auto-detected bus/address).
        key = self._identity_key(
            self.vid,
            self.pid,
            getattr(self.dev, "bus", self.bus) if self.dev is not None else self.bus,
            getattr(self.dev, "address", self.address) if self.dev is not None else self.address,
            self.serial_number or (self._device_serial(self.dev) if self.dev else None),
        )
        self.bus = key[2]
        self.address = key[3]
        if key[4]:
            self.serial_number = key[4]
        self._registry_key = key
        type(self)._instances[key] = self
        type(self)._instance = self

    @classmethod
    def get_instance(
        cls,
        vid: int = DEFAULT_VID,
        pid: int = DEFAULT_PID,
        bus: Optional[int] = None,
        address: Optional[int] = None,
        serial_number: Optional[str] = None,
    ) -> "CH341Async":
        """Return an open CH341 handle for the selected USB device.

        Selection (first match wins when fully specified):
        - serial_number
        - bus + address
        - bus only / address only (if unique)
        - no filters: ok only when exactly one VID/PID match exists
        """
        sn = (serial_number or "").strip() or None

        # Exact registry hit when fully specified.
        if bus is not None and address is not None:
            key = cls._identity_key(vid, pid, bus, address, sn)
            existing = cls._instances.get(key)
            if existing is not None and getattr(existing, "_initialized", False):
                return existing
            # Also try without serial in key if serial omitted.
            if sn is None:
                for k, inst in list(cls._instances.items()):
                    if k[0] == int(vid) and k[1] == int(pid) and k[2] == bus and k[3] == address:
                        if getattr(inst, "_initialized", False):
                            return inst

        if sn is not None:
            for k, inst in list(cls._instances.items()):
                if k[0] == int(vid) and k[1] == int(pid) and k[4] == sn:
                    if getattr(inst, "_initialized", False):
                        return inst

        # Legacy: no filters and exactly one live instance with same vid/pid.
        if bus is None and address is None and sn is None:
            same = [
                inst
                for inst in cls._instances.values()
                if getattr(inst, "_initialized", False)
                and getattr(inst, "vid", None) == int(vid)
                and getattr(inst, "pid", None) == int(pid)
            ]
            if len(same) == 1:
                return same[0]

        return cls(
            vid=vid,
            pid=pid,
            bus=bus,
            address=address,
            serial_number=sn,
        )

    @classmethod
    def reset_instance(cls) -> None:
        """Close and forget all open CH341 instances (tests / shutdown)."""
        logger.info("Resetting CH341 instance registry (%d open)", len(cls._instances))
        for inst in list(cls._instances.values()):
            try:
                inst.close()
            except Exception as e:
                logger.warning(f"Error during reset_instance close: {e}")
        cls._instances.clear()
        cls._instance = None
        time.sleep(0.1)

    @staticmethod
    def reverse_byte(b: int) -> int:
        """Reverse bit order in a byte."""

        result = 0
        for _ in range(8):
            result = (result << 1) | (b & 1)
            b >>= 1
        return result

    def _is_timeout(self, e: Exception) -> bool:
        if not isinstance(e, usb.core.USBError):
            return False
        if getattr(e, "errno", None) in (errno.ETIMEDOUT, 110):
            return True
        return "timed out" in str(e).lower()

    def _open_device(self) -> None:
        """Find, configure, and claim the selected CH341 device."""

        self.dev = self._find_device(
            self.vid,
            self.pid,
            bus=self.bus,
            address=self.address,
            serial_number=self.serial_number,
        )

        # Set configuration (safe to call even if already set; some backends may raise EBUSY).
        try:
            self.dev.set_configuration()
        except usb.core.USBError as e:
            if getattr(e, "errno", None) not in (errno.EBUSY, 16):
                raise CH341Error(f"Failed to set USB configuration: {e}") from e

        # Detach kernel driver if active (Linux)
        try:
            if self.dev.is_kernel_driver_active(0):
                try:
                    self.dev.detach_kernel_driver(0)
                except usb.core.USBError as e:
                    logger.warning(f"Could not detach kernel driver: {e}")
        except (NotImplementedError, AttributeError):
            pass

        # Claim interface 0
        try:
            usb.util.claim_interface(self.dev, 0)
        except usb.core.USBError as e:
            if getattr(e, "errno", None) in (errno.EBUSY, 16):
                logger.error("Device is busy (claimed by another process or driver)")
                logger.error("Try: 1) stop other processes, or 2) unplug/replug device")
            raise CH341Error(f"Failed to claim interface 0: {e}") from e

        # Locate endpoints
        cfg = self.dev.get_active_configuration()
        intf = cfg[(0, 0)]

        self._ep_out = usb.util.find_descriptor(intf, bEndpointAddress=self.EP_OUT)
        self._ep_in = usb.util.find_descriptor(intf, bEndpointAddress=self.EP_IN)

        if self._ep_out is None or self._ep_in is None:
            raise CH341Error(
                f"Could not find expected endpoints "
                f"EP_OUT=0x{self.EP_OUT:02x}, EP_IN=0x{self.EP_IN:02x}"
            )

        # Initialize GPIO/pinmux (required before SPI transfers)
        self.gpio_dir = (1 << 0) | (1 << 3) | (1 << 5)
        self.gpio_state = self.gpio_dir  # deassert CS + idle-high on SCK/MOSI

        try:
            self._uio_stream(
                out=self.gpio_state, direction=self.gpio_dir, timeout_ms=self.USB_TIMEOUT
            )
            logger.debug("CH341 GPIO/pinmux initialized")
        except Exception as e:
            logger.warning(f"Failed to send UIO init command: {e}")

        # Drain any stale bytes from EP_IN.
        try:
            for _ in range(32):
                try:
                    data = self._ep_in.read(64, timeout=10)
                except usb.core.USBError as e:
                    if self._is_timeout(e):
                        break
                    break
                if not data:
                    break
        except Exception:
            pass

        logger.info(
            "CH341 opened: VID=%04x PID=%04x bus=%s address=%s serial=%r",
            self.vid,
            self.pid,
            getattr(self.dev, "bus", None),
            getattr(self.dev, "address", None),
            self._device_serial(self.dev),
        )

    def close(self) -> None:
        """Release interface and dispose USB resources."""

        if self.dev is None:
            return

        try:
            try:
                usb.util.release_interface(self.dev, 0)
            except Exception:
                pass
            usb.util.dispose_resources(self.dev)
        finally:
            self.dev = None
            self._ep_out = None
            self._ep_in = None
            self._initialized = False
            key = getattr(self, "_registry_key", None)
            if key is not None:
                type(self)._instances.pop(key, None)
            if type(self)._instance is self:
                type(self)._instance = next(iter(type(self)._instances.values()), None)

    def _bulk_write_all(self, payload: bytes, timeout_ms: Optional[int] = None) -> None:
        if self.dev is None or self._ep_out is None:
            raise CH341Error("Device not open")

        if timeout_ms is None:
            timeout_ms = self.USB_TIMEOUT

        if not payload:
            return

        offset = 0
        while offset < len(payload):
            try:
                written = int(self._ep_out.write(payload[offset:], timeout=timeout_ms))
            except usb.core.USBError as e:
                raise CH341SPIError(f"SPI OUT bulk transfer failed: {e}") from e
            if written <= 0:
                raise CH341SPIError("SPI OUT bulk transfer short write (0 bytes)")
            offset += written

    def _bulk_read_exact(self, nbytes: int, timeout_ms: Optional[int] = None) -> bytes:
        if self.dev is None or self._ep_in is None:
            raise CH341Error("Device not open")

        if timeout_ms is None:
            timeout_ms = self.USB_TIMEOUT

        if nbytes <= 0:
            return b""

        out = bytearray()
        while len(out) < nbytes:
            try:
                chunk = self._ep_in.read(nbytes - len(out), timeout=timeout_ms)
            except usb.core.USBError as e:
                raise CH341SPIError(f"SPI IN bulk transfer failed: {e}") from e
            if not chunk:
                raise CH341SPIError("SPI IN bulk transfer short read (0 bytes)")
            out.extend(bytes(chunk))
        return bytes(out)

    def spi_transfer_async(self, data_out: bytes, read_len: int = 0) -> bytes:
        """Perform SPI transfer.

        The CH341 returns one byte for each payload byte clocked.

        If read_len > 0, additional 0xFF bytes are clocked out to read more data.
        """

        with self._operation_lock:
            with self._transfer_lock:
                return self._spi_transfer_impl_core(data_out, read_len)

    def _spi_transfer_impl_core(self, data_out: bytes, read_len: int = 0) -> bytes:
        if not data_out and read_len == 0:
            return b""

        writecnt = len(data_out)
        readcnt = int(read_len)

        write_left = writecnt
        read_left = readcnt
        write_idx = 0

        miso_raw = bytearray()

        while write_left > 0 or read_left > 0:
            write_now = min(self.MAX_PAYLOAD, write_left)
            read_now = min(self.MAX_PAYLOAD - write_now, read_left)

            packet = bytearray([self.CMD_SPI_STREAM])

            for i in range(write_now):
                packet.append(self.reverse_byte(data_out[write_idx + i]))

            if read_now > 0:
                packet.extend([0xFF] * read_now)

            self._bulk_write_all(bytes(packet), timeout_ms=self.USB_TIMEOUT)
            miso_raw.extend(
                self._bulk_read_exact(write_now + read_now, timeout_ms=self.USB_TIMEOUT)
            )

            write_idx += write_now
            write_left -= write_now
            read_left -= read_now

        if readcnt > 0:
            return bytes(self.reverse_byte(b) for b in miso_raw[writecnt : writecnt + readcnt])
        return bytes(self.reverse_byte(b) for b in miso_raw[:writecnt])

    def _uio_stream(
        self,
        *,
        out: Optional[int] = None,
        direction: Optional[int] = None,
        timeout_ms: Optional[int] = None,
    ) -> None:
        cmd = bytearray([self.CMD_UIO_STREAM])
        if out is not None:
            cmd.append(self.CMD_UIO_STM_OUT | (out & 0xFF))
        if direction is not None:
            cmd.append(self.CMD_UIO_STM_DIR | (direction & 0xFF))
        cmd.append(self.CMD_UIO_STM_END)

        # UIO operations must not overlap with SPI.
        self._bulk_write_all(bytes(cmd), timeout_ms=timeout_ms)

    def gpio_set(self, pin: int, value: bool):
        with self._operation_lock:
            with self._transfer_lock:
                return self._gpio_set_impl(pin, value)

    def _gpio_set_impl(self, pin: int, value: bool):
        if pin < 0 or pin > 5:
            raise ValueError(f"GPIO pin must be 0-5, got {pin}")

        if value:
            self.gpio_state |= 1 << pin
        else:
            self.gpio_state &= ~(1 << pin)

        self._uio_stream(out=self.gpio_state, direction=self.gpio_dir)

    def gpio_set_direction(self, pin: int, is_output: bool):
        with self._operation_lock:
            with self._transfer_lock:
                return self._gpio_set_direction_impl(pin, is_output)

    def _gpio_set_direction_impl(self, pin: int, is_output: bool):
        if pin < 0 or pin > 15:
            raise ValueError(f"GPIO pin must be 0-15, got {pin}")

        if pin > 5 and is_output:
            raise ValueError(f"GPIO pin {pin} only supports input mode (pins 6-7 are input-only)")

        if is_output:
            self.gpio_dir |= 1 << pin
        else:
            self.gpio_dir &= ~(1 << pin)

        self._uio_stream(direction=self.gpio_dir)

    def gpio_get(self, pin: int) -> bool:
        acquired = self._operation_lock.acquire(timeout=0.01)
        if not acquired:
            # Preserve the old "BUSY" string; the GPIO poller filters it.
            raise CH341Error("GPIO read IN failed: -6")
        try:
            with self._transfer_lock:
                return self._gpio_get_impl(pin)
        finally:
            self._operation_lock.release()

    def _gpio_get_impl(self, pin: int) -> bool:
        if pin < 0 or pin > 15:
            raise ValueError(f"GPIO pin must be 0-15, got {pin}")

        GPIO_READ_BYTES = 6
        GPIO_READ_TIMEOUT_MS = 200

        try:
            self._bulk_write_all(bytes([self.CMD_UIO_READ]), timeout_ms=GPIO_READ_TIMEOUT_MS)
        except Exception as e:
            raise CH341Error(f"GPIO read write failed: {e}") from e

        try:
            data = self._bulk_read_exact(GPIO_READ_BYTES, timeout_ms=GPIO_READ_TIMEOUT_MS)
        except Exception as e:
            raise CH341Error(f"GPIO read IN failed: {e}") from e

        if pin < 8:
            return bool(data[0] & (1 << pin))
        else:
            return bool(data[1] & (1 << (pin - 8)))

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False
