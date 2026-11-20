# Validation checklist

Record the firmware revision, radio USB identity, regional profile, GPS source and payload commit for every physical test. Never publish captures containing locations, identifiers or private message content as test fixtures.

## Automated checks

From the project root, run `python -m unittest discover -s tests -v` and `bash -n payload/payload.sh`. Tests cover parser bounds, known-key cryptography, signed MeshCore advertisements, raw radio metadata, LoRaTAP layout, session persistence, GPS expiry, configuration handling and mocked upload receipts. They do not establish RF reception or service acceptance.

## On the Pager

- Launch from Payloads; verify the three-logo splash, native menu selection, Back and Exit.
- Confirm region selection is required for a new installation and survives a restart.
- Confirm the USB bridge is present and no other program owns it. Start and stop capture twice.
- Send a known Meshtastic broadcast using the selected profile. Compare exact raw bytes/IDs and decoded fields to a reference receiver.
- Repeat with a MeshCore signed advert and Public-channel message; check invalid-signature handling with offline fixtures only.
- In Both mode, observe profile changes and measure missed packets against the reference receiver. Do not claim simultaneous reception.
- Test a valid GPS fix, lost fix, stale data, GPS disconnect and no GPS. Ensure missing locations remain missing.
- Start native tri-band Wi-Fi capture independently, run LoRa at the same time, and verify responsive menus and valid native CSV/PCAP. Stop native capture and attach its files.
- Stop normally and compare JSONL count, SQLite observation count and PCAP packet count. Confirm every later sighting remains in observations.
- Unplug the radio during capture; verify interrupted status, retained files and error reporting.
- Test storage-reserve handling on a test filesystem; do not fill the user's working storage.
- Terminate the collector during a test session; reopen SQLite and verify that incomplete sessions do not auto-upload.
- With explicit account/data authorization, test one small eligible upload to each service and record actual processing/import counts. Never infer this from mocked tests.

## Release gate

Before an upstream PR, include the tested Pager firmware revision and radio variant, documented dependencies, source/licensing notices and real device results. Open issues must remain visible. No custom binaries, credentials, captured wardrives or private configuration belong in the submitted payload directory.
