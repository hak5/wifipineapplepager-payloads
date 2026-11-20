# Device validation record

These results describe development build 0.1.0 tested on November 17–18, 2026.
They are evidence for the tested configuration, not a claim of upstream
acceptance or complete LoRaPipe/Kismet feature parity. Captured identifiers,
message contents, coordinates and private device configuration are excluded.

## Test environment

- Hak5 WiFi Pineapple Pager, firmware revision
  `20261019-0027-ga0cd21f-dirty`, OpenWrt 24.10.1, MIPS little endian.
- Glytch Mesh Mod, CH341 USB-SPI identity `1a86:5512`, SX1262.
- Python 3.11.14 on the Pager; `python3-cryptography` 41.0.7 from its configured
  package feed; bundled unmodified PyUSB 1.3.1 source.
- US Meshtastic LongFast: 906.875 MHz, 250 kHz bandwidth, SF11, CR4/5.
- Both mode also selected the US MeshCore starting profile: 910.525 MHz,
  62.5 kHz bandwidth, SF7, CR4/5. The schedule was observed; no known MeshCore
  transmitter was available to verify reception on that profile.
- An external USB GPS receiver connected alongside the radio through a hub.
  The `10c4:ea60` bridge identity alone does not establish the GNSS model.
  Live NMEA sentences confirmed that the selected port was a GPS receiver.

## Completed checks

| Check | Observed result |
| --- | --- |
| Host unit tests | 105 run: 104 passed; one Windows symbolic-link permission test skipped. The same suite passed from the actual isolated upstream contribution directory |
| Python syntax | Payload and tools compile under local Python 3.11 |
| Bash/native UI mocks | Syntax, confirmation, owned-process cleanup and unrelated-process preservation passed |
| Contribution review | 53 files prepared only under the proposed payload directory: 41 runtime/source/asset files, 11 test files and one audit utility. No captures, private configuration, compiled caches or custom executable |
| Pager AES | Known-vector self-test passed; actual Meshtastic decoding subsequently succeeded |
| Pager Ed25519 | RFC 8032 known-signature self-test passed in Both mode |
| Native startup and controls | Three-logo splash, account handle, menu and status dialog displayed through the Payloads runner. Final startup dependency checks passed; native capture start/stop was confirmed |
| Recent-packet display | The final two decoded Meshtastic records displayed on the physical Pager, with bounded lines containing claimed sender identity, observation time, decode state, RSSI and profile |
| Device-summary display | Stored Meshtastic identities, last-seen times, signal levels and profiles rendered on the physical Pager. Packet identifiers and contents are excluded from the published screenshots |
| Fixed-profile reception | Baseline capture retained 19 packets: 18 decoded Meshtastic records and one encrypted record, before receiver GPS was connected |
| First geolocated Both-mode capture | 311 seconds; eight Meshtastic packets decoded; 11 radio configurations including the initial setup, meaning ten profile changes |
| Final runtime Both-mode capture | 578 seconds; two Meshtastic packets decoded; 19 radio configurations including the initial setup, meaning 18 profile changes |
| Capture consistency | All retained raw packets matched in order across JSONL, SQLite and LoRaTAP PCAP. The geolocated and final captures also matched full JSONL and SQLite observation records |
| Final runtime error counters | Zero CRC, header, malformed-packet, queue-drop, decoder and write errors |
| Receiver location handling | Five of eight packets in the first Both-mode capture had fresh 3D fixes; three had no fix and no coordinates. Both final-runtime packets arrived without a valid fix, so coordinates and valid receiver UTC were absent |
| Native Wi-Fi alongside LoRa | An existing CSV recording continued from 199 to 204 records during the first geolocated check. Native GPS reported a 3D fix with four to six satellites; native packet counters were nonzero in the 2.4, 5 and 6 GHz bands |
| Native PCAP test | A separate test PCAP was started and stopped through the documented Pager commands, then explicitly attached through the payload CLI. The existing CSV recording remained under its original owner and was preserved |
| Attached native files | A 38,350-byte CSV snapshot and the closed 1,319,081-byte PCAP were attached with exact matching hashes; original native files were retained |
| Native PCAP structure | 7,078 frames, DLT 127, snaplen 8,192, and 1,205,809 captured payload bytes. All record boundaries passed validation |
| Offline export | One Wi-Fi artifact with 231 eligible rows; 45 rows skipped as `wifi_invalid_or_missing_fix`; two mesh observations skipped as `mesh_not_eligible`. Originals were retained and no network upload occurred |
| Automatic-upload opt-out | With every upload service disabled, the on-device automatic-upload path returned without HTTP requests |

The baseline capture was not geolocated. The final runtime was built from runtime
source commit `539da568dbe8e5da77210547364abfe88063bc09`. The installed archive
identities for the three receive checks were:

| Capture | Installed archive SHA-256 |
| --- | --- |
| Baseline, 19 packets | `91623a7b16b832d49a8ba35a9ce168bb95499aa657ea31f4e7e73e116ac584e5` |
| First geolocated Both-mode check, eight packets | `0f5e7c07db954513e81a71b0e4e6e29b95cb6b51f833b8b0d4dcc6db0b9b44b6` |
| Final runtime Both-mode check, two packets | `60b8cd9aa19876473c3740af42239367491148cdc6b7fd73f08d1907ba06771a` |

Documentation and review-test additions change the distribution archive hash
without changing the tested runtime. Each packaged archive has its own adjacent
SHA-256 file; the hashes above identify the versions actually installed for
these checks.

The attached native PCAP contains 5,495 records whose captured length is smaller
than the reported original frame length. These are native capture truncations,
not broken file boundaries. Full original frame contents cannot be recovered
from those records. Native band counters demonstrate observed activity, not
continuous reception of every channel or a measured capture-completeness rate.

A final integration audit checked raw-byte consistency, full JSONL/SQLite
records, omission of coordinates for invalid fixes, PCAP bounds, attached-file
hashes and manifest consistency. No live capture identifiers, coordinates or
message contents are included in this record.

## Issues found and addressed

The installed cryptography package imported successfully but initially failed
when OpenSSL tried to load its legacy provider from the MMC environment. The
payload uses the supported process-local `CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1`
setting. AES and Ed25519 use the default provider. Raw reception is independent
of decoding, so a decoder failure cannot discard a received packet.

Connecting the GPS through a hub changed its USB path. In addition, the native
PineAP serial owner prevented gpsd from starting. The original device settings
were backed up privately, the verified receiver path was selected, and PineAP
was configured to share gpsd. Both the payload and native Pager subsequently
reported valid fixes. Reception was intermittent: the first geolocated capture
had five fresh-fix observations and three without a fix, and neither final
packet coincided with a valid fix. This confirms correct handling of available
and missing positions; it does not establish reliable outdoor acquisition or
continuous GPS coverage. The firmware-specific setup procedure is documented
in [INSTALL.md](INSTALL.md).

## Remaining acceptance work

- Live MeshCore reception and decoding from a known transmitter.
- Actual LoRaPipe serial hardware, separate from the tested Glytch USB backend.
- Long-drive stability, stable outdoor GPS acquisition and sustained fix
  recovery, hub reconnect and radio disconnect.
- Import into actual Kismet/Wireshark; a valid LoRaTAP serializer is not an
  end-to-end interoperability test. The SQLite database is not KismetDB.
- Real, authorized upload/import acceptance by WiGLE, Wardrift and WDGWars.
  Upload tests use simulated transports; no capture was sent to these services.
- Hak5 review and acceptance remain separate from these validation results.

## Repeating the capture audit

After stopping a capture cleanly, run the read-only audit tool from the full
development checkout or the upstream contribution directory, which includes
`tests/` and `tools/audit_session.py`. The compact installation archive may omit
these review utilities:

```sh
python3 tools/audit_session.py /path/to/closed/session
```

It checks session state, schema versions, record bounds, PCAP headers, ordered
raw-byte equality, saved counts, SQLite record consistency and whether the files
changed during the check. Its output contains aggregate counts and fixed error
labels, not packet contents or coordinates. Preserve the original session files;
an audit failure is not a reason to delete or silently rewrite a capture.
