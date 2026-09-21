#!/usr/bin/env python3
"""
bt_fingerprint.py - BT/BLE Device Fingerprinting für Chasing Your Tail NG v4.4
Mappt Service UUIDs, Appearance Codes und Gerätenamen → Risikobewertung.
Keine externen Abhängigkeiten.
"""

# Risiko-Level
RISK_NONE   = 'none'
RISK_LOW    = 'low'
RISK_MEDIUM = 'medium'
RISK_HIGH   = 'high'

_RISK_ORDER = [RISK_NONE, RISK_LOW, RISK_MEDIUM, RISK_HIGH]

def _max_risk(a, b):
    return b if _RISK_ORDER.index(b) > _RISK_ORDER.index(a) else a

def risk_emoji(risk):
    return {'none': '🟢', 'low': '🔵', 'medium': '🟡', 'high': '🔴'}.get(risk, '⚪')

# ============================================================
# SERVICE UUID DATENBANK
# UUID (4 hex, lowercase) → (label, has_mic, risk_level)
# ============================================================

SERVICE_UUID_DB = {
    # === BT Classic Profile UUIDs ===
    '1101': ('Serial Port (SPP)',              False, RISK_LOW),
    '1105': ('OPP File Transfer',              False, RISK_LOW),
    '1106': ('OBEX File Transfer',             False, RISK_LOW),
    '1108': ('Headset HSP',                    True,  RISK_MEDIUM),  # 🎤 Mikrofon
    '110a': ('A2DP Audio Source',              False, RISK_LOW),
    '110b': ('A2DP Audio Sink (Kopfhörer)',    False, RISK_LOW),
    '110c': ('A2DP Remote Control Target',     False, RISK_LOW),
    '110e': ('A2DP Remote Control',            False, RISK_LOW),
    '1112': ('Headset Audio Gateway',          True,  RISK_MEDIUM),  # 🎤 Mikrofon
    '1115': ('PAN Network (PANU)',             False, RISK_LOW),
    '1116': ('PAN Network (NAP)',              False, RISK_LOW),
    '1124': ('HID Device',                     False, RISK_LOW),
    '111e': ('Handsfree HFP',                  True,  RISK_MEDIUM),  # 🎤 Mikrofon
    '111f': ('Handsfree Audio Gateway',        True,  RISK_MEDIUM),  # 🎤 Mikrofon
    '112d': ('SIM Access Profile',             False, RISK_MEDIUM),
    '112f': ('Phonebook Access (PBAP)',        False, RISK_MEDIUM),
    '1132': ('Message Access (MAP)',           False, RISK_MEDIUM),

    # === BLE GATT Services ===
    '1800': ('Generic Access',                 False, RISK_NONE),
    '1801': ('Generic Attribute',              False, RISK_NONE),
    '1802': ('Immediate Alert',                False, RISK_LOW),
    '1803': ('Link Loss',                      False, RISK_LOW),
    '1804': ('TX Power',                       False, RISK_NONE),
    '1805': ('Current Time',                   False, RISK_NONE),
    '180a': ('Device Information',             False, RISK_NONE),
    '180d': ('Heart Rate Monitor',             False, RISK_LOW),
    '180e': ('Phone Alert / Mic-capable',      True,  RISK_MEDIUM),
    '180f': ('Battery Service',                False, RISK_NONE),
    '1812': ('HID / Input Device',             False, RISK_LOW),
    '1819': ('Location & Navigation',          False, RISK_MEDIUM),  # Tracker
    '181a': ('Environmental Sensing',          False, RISK_LOW),
    '181c': ('User Data',                      False, RISK_LOW),
    '181e': ('Bond Management',                False, RISK_LOW),
    '1820': ('IP Support (IoT)',               False, RISK_MEDIUM),
    '1821': ('Indoor Positioning',             False, RISK_MEDIUM),  # Tracker
    '1823': ('HTTP Proxy (IoT Gateway)',        False, RISK_MEDIUM),
    '1826': ('Fitness Machine',                False, RISK_LOW),
    '1827': ('BT Mesh Provisioning',           False, RISK_MEDIUM),  # IoT-Netz
    '1828': ('BT Mesh Proxy',                  False, RISK_MEDIUM),  # IoT-Netz
    '1843': ('Audio Input Control',            True,  RISK_MEDIUM),  # 🎤 Mikrofon
    '184e': ('Audio Stream',                   True,  RISK_MEDIUM),  # 🎤 Mikrofon

    # === Proprietary / Vendor UUIDs ===
    'fd6f': ('COVID Contact Tracing',          False, RISK_NONE),
    'fd87': ('Apple MagSafe',                  False, RISK_NONE),
    'fe2c': ('Apple AirDrop / AirPods',        False, RISK_LOW),
    'fe59': ('Nordic UART / Audio',            True,  RISK_MEDIUM),  # 🎤 Mikrofon möglich
    'fe8b': ('Apple iPhone Service',           False, RISK_LOW),
    'febe': ('Apple Proprietary',              False, RISK_LOW),
    'fe9f': ('Google Nearby / Chromecast',     False, RISK_LOW),
    'feaa': ('Eddystone Beacon',               False, RISK_MEDIUM),  # Tracker
    'ffe0': ('Camera Control Service',         False, RISK_HIGH),    # 📷 Kamera!
    'ffe1': ('Camera Data Stream',             False, RISK_HIGH),    # 📷 Kamera!
    'fff0': ('IoT Proprietary Control',        False, RISK_MEDIUM),
    'fff1': ('IoT Data Service',               False, RISK_LOW),
    'ff00': ('Unknown Proprietary',            False, RISK_MEDIUM),
}

# ============================================================
# APPEARANCE CODE DATENBANK
# Code → (label, is_suspicious)
# ============================================================

APPEARANCE_DB = {
    0x0000: ('Unbekannt',               False),
    0x0040: ('Handy',                   False),
    0x0041: ('Smartphone',              False),
    0x0080: ('PC',                      False),
    0x0081: ('Desktop-PC',              False),
    0x0082: ('Laptop',                  False),
    0x0083: ('Handheld-PC',             False),
    0x0084: ('Palmtop',                 False),
    0x0085: ('Tablet',                  False),
    0x00C0: ('Uhr',                     False),
    0x00C1: ('Sport-Uhr',               False),
    0x00C2: ('Smartwatch',              False),
    0x0100: ('Wecker',                  False),
    0x0140: ('Display',                 False),
    0x0180: ('Fernbedienung',           False),
    0x01C0: ('Smart Glasses',           True),   # Kamera möglich
    0x0200: ('Tag / Tracker',           True),
    0x0240: ('Schlüsselanhänger',       True),
    0x0280: ('Mediaplayer',             False),
    0x02C0: ('Barcode-Scanner',         False),
    0x0300: ('Thermometer',             False),
    0x0340: ('Herzfrequenzsensor',      False),
    0x03C0: ('HID-Gerät',               False),
    0x03C1: ('Tastatur',                False),
    0x03C2: ('Maus',                    False),
    0x03C4: ('Gamepad',                 False),
    0x03C9: ('Kartenleser',             False),
    0x0440: ('Digitaler Stift',         False),
    0x07C0: ('Smart-Lampe',             False),
    0x07C1: ('Smart-Steckdose',         True),   # IoT
    0x07C6: ('Zugangskontrolle',        True),   # Überwachung
    0x07C9: ('Netzwerkgerät',           True),   # IoT
    0x07CA: ('Lichtsensor',             False),
    0x07CB: ('Bewegungsmelder (BLE)',   True),   # Überwachung!
    0x07CC: ('PIR Sensor',              True),   # Überwachung!
    0x07D4: ('IP-Kamera',              True),   # 📷 KAMERA!
    0x07D5: ('Videokamera',             True),   # 📷 KAMERA!
    0x07D6: ('Audio-Sensor',            True),   # 🎤 Mikrofon!
    0x07D7: ('Präsenzsensor',           True),   # Überwachung
    0x07D8: ('Umgebungssensor',         False),
    0x0C40: ('Mediaplayer',             False),
    0x0C41: ('Set-Top-Box',             False),
    0x0C42: ('DVR',                     False),
    0x0C44: ('AV-Receiver',             False),
    0x0C46: ('Videokamera',             True),   # 📷 KAMERA!
    0x0C48: ('Videomonitor',            False),
    0x0C49: ('Fernseher',               False),
    0x0C4A: ('Videokonferenz',          True),   # Kamera + Mikrofon
    0x0C4B: ('Digitalkamera',           True),   # 📷 KAMERA!
    0x0C4C: ('Digitale Videokamera',    True),   # 📷 KAMERA!
}

# Appearance Codes die eindeutig auf Kamera hinweisen
_CAMERA_APPEARANCE_CODES = {0x07D4, 0x07D5, 0x0C46, 0x0C4B, 0x0C4C}
# Appearance Code für Audio-Sensor (Mikrofon)
_AUDIO_APPEARANCE_CODES  = {0x07D6, 0x0C4A}

# ============================================================
# GERÄTENAMEN MUSTER
# ============================================================

_MIC_NAME_PATTERNS = [
    'headset', 'earbuds', 'airpods', 'galaxy buds', 'jabra', 'plantronics',
    'poly ', 'bose', 'sony wh', 'sony wf', 'beats', 'sennheiser',
    'echo ', 'alexa', 'google home', 'nest mini', 'homepod',
    'macbook', 'surface pro', 'thinkpad',
]

_CAMERA_NAME_PATTERNS = [
    'ipcam', 'ip cam', 'ip-cam', 'camera', 'cam_', 'cam-',
    'hikvision', 'dahua', 'reolink', 'wyze', 'arlo', 'ring',
    'foscam', 'eufy', 'ezviz', 'amcrest', 'annke',
    'esp32-cam', 'esp32cam', 'esp8266', 'espcam',
]

# ============================================================
# KAMERA-HERSTELLER OUI (BT MAC Lookup)
# ============================================================

CAMERA_OUI_PREFIXES = {
    '9c:b8:b5': 'Hikvision',
    'ac:cc:8e': 'Hikvision',
    'c8:02:10': 'Hikvision',
    'f0:9e:4a': 'Hikvision',
    'b4:a3:82': 'Hikvision',
    'd0:75:a7': 'Hikvision',
    '54:c4:15': 'Hikvision',
    'a0:e4:cb': 'Dahua',
    '70:6a:eb': 'Dahua',
    '7c:c2:c6': 'Reolink',
    'ec:71:db': 'Wyze',
    'a8:5b:4f': 'Wyze',
    '2c:aa:8e': 'Arlo',
    'e0:9a:d9': 'Arlo',
    '30:8c:fb': 'Eufy',
    '64:a2:f9': 'Ring',
    'b0:09:da': 'Ring',
    'c4:de:e2': 'Nest/Google',
    '18:b4:30': 'Nest/Google',
    # Espressif (ESP32/ESP8266) - häufig in DIY/Billig-Kameras
    '68:02:b8': 'Espressif (IoT)',
    '10:52:1c': 'Espressif (IoT)',
    'a4:cf:12': 'Espressif (IoT)',
    '24:0a:c4': 'Espressif (IoT)',
    'cc:50:e3': 'Espressif (IoT)',
    '84:f3:eb': 'Espressif (IoT)',
    'ec:fa:bc': 'Espressif (IoT)',
    '30:ae:a4': 'Espressif (IoT)',
    '24:6f:28': 'Espressif (IoT)',
    'c4:4f:33': 'Espressif (IoT)',
    '7c:df:a1': 'Espressif (IoT)',
    'b4:e6:2d': 'Espressif (IoT)',
    '08:3a:f2': 'Espressif (IoT)',
    'e8:68:e7': 'Espressif (IoT)',
    # Realtek
    '00:00:6c': 'Realtek (IoT)',
    '00:e0:4c': 'Realtek (IoT)',
}

# ============================================================
# FINGERPRINT FUNKTION
# ============================================================

def fingerprint_device(mac, name='', uuids=None, appearance_code=None, oui_vendor=''):
    """
    Bewertet ein BT/BLE-Gerät anhand von UUIDs, Appearance, Name, OUI.

    Args:
        mac:             MAC-Adresse (lowercase, colon-separated)
        name:            Gerätename (aus Advertisement oder Scan)
        uuids:           Liste von 4-stelligen hex UUID-Strings
        appearance_code: BLE Appearance Code (int) oder None
        oui_vendor:      Herstellername aus IEEE OUI-Lookup

    Returns:
        dict mit: risk, has_mic, has_camera, device_type, flags
    """
    uuids = [u.lower().strip() for u in (uuids or [])]
    name_lower = (name or '').lower()

    risk        = RISK_NONE
    has_mic     = False
    has_camera  = False
    device_types = []
    flags        = []

    # 1. Service UUIDs auswerten
    for uuid in uuids:
        uuid_short = uuid[-4:] if len(uuid) > 4 else uuid
        if uuid_short in SERVICE_UUID_DB:
            label, mic, uuid_risk = SERVICE_UUID_DB[uuid_short]
            if label not in device_types:
                device_types.append(label)
            if mic:
                has_mic = True
                flags.append(f'🎤 Mikrofon via {label} ({uuid_short})')
            if uuid_short in ('ffe0', 'ffe1'):
                has_camera = True
                flags.append(f'📷 Kamera-Service UUID: {uuid_short}')
            risk = _max_risk(risk, uuid_risk)

    # 2. Appearance Code auswerten
    if appearance_code is not None:
        app_label, suspicious = APPEARANCE_DB.get(
            appearance_code, (f'0x{appearance_code:04x}', False)
        )
        if app_label not in device_types:
            device_types.insert(0, app_label)
        if appearance_code in _CAMERA_APPEARANCE_CODES:
            has_camera = True
            risk = RISK_HIGH
            flags.append(f'📷 KAMERA (Appearance 0x{appearance_code:04x}: {app_label})')
        elif appearance_code in _AUDIO_APPEARANCE_CODES:
            has_mic = True
            risk = _max_risk(risk, RISK_MEDIUM)
            flags.append(f'🎤 Audio-Sensor (Appearance 0x{appearance_code:04x})')
        elif suspicious:
            risk = _max_risk(risk, RISK_MEDIUM)
            flags.append(f'⚠ Verdächtiger Typ: {app_label}')

    # 3. Gerätename auswerten
    for pattern in _CAMERA_NAME_PATTERNS:
        if pattern in name_lower:
            has_camera = True
            risk = RISK_HIGH
            flags.append(f'📷 Kamera-Name: "{name}"')
            break

    if not has_camera:
        for pattern in _MIC_NAME_PATTERNS:
            if pattern in name_lower:
                has_mic = True
                risk = _max_risk(risk, RISK_MEDIUM)
                flags.append(f'🎤 Headset/Speaker: "{name}"')
                break

    # 4. OUI check (Kamera-Hersteller via eigene DB)
    mac_oui = mac.lower()[:8] if mac else ''
    cam_vendor = CAMERA_OUI_PREFIXES.get(mac_oui)
    if cam_vendor:
        risk = _max_risk(risk, RISK_MEDIUM)
        flags.append(f'⚠ OUI Kamera-Hersteller: {cam_vendor}')
        if 'Espressif' in cam_vendor or 'Realtek' in cam_vendor:
            flags.append('⚠ IoT-Chip (DIY-Kamera möglich)')

    # 5. IEEE OUI-Vendor (Espressif, Realtek, MediaTek = IoT-Hinweis)
    if oui_vendor and any(v in oui_vendor for v in ['Espressif', 'Realtek', 'MediaTek']):
        risk = _max_risk(risk, RISK_MEDIUM)
        if not any('IoT' in f for f in flags):
            flags.append(f'⚠ IoT-Chip-Hersteller: {oui_vendor}')

    device_type = device_types[0] if device_types else 'Unbekannt'

    return {
        'risk':        risk,
        'has_mic':     has_mic,
        'has_camera':  has_camera,
        'device_type': device_type,
        'all_types':   device_types,
        'flags':       flags,
        'uuids':       uuids,
    }


# ============================================================
# MAIN (Test)
# ============================================================
if __name__ == '__main__':
    tests = [
        ('aa:bb:cc:dd:ee:01', 'JBL Earbuds',     ['111e', '110b'],  0x0040,  ''),
        ('aa:bb:cc:dd:ee:02', 'ESP32-CAM',        ['ffe0', 'ffe1'],  None,    'Espressif'),
        ('68:02:b8:11:22:33', '',                  ['180a'],         None,    'Espressif Inc.'),
        ('aa:bb:cc:dd:ee:04', 'Apple Watch',       ['180d', '180f'], 0x00C2,  'Apple'),
        ('aa:bb:cc:dd:ee:05', 'IP-Camera-Hikvision', [],            0x07D4,  ''),
    ]

    for mac, name, uuids, app, vendor in tests:
        fp = fingerprint_device(mac, name, uuids, app, vendor)
        emoji = risk_emoji(fp['risk'])
        print(f'{emoji} {mac} | {name or "?":20} | {fp["risk"]:6} | '
              f'mic={fp["has_mic"]} cam={fp["has_camera"]} | {fp["device_type"]}')
        for flag in fp['flags']:
            print(f'     {flag}')
