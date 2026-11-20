# Exports and optional uploads

LORA-Pager-Pipe records locally first. Exporting does not need an account or
network connection. Uploads are off until the operator configures and enables a
destination. Each service has a separate automatic-upload switch; entering an
API key alone does not enable it.

Only a session with `session.json` status `closed` can be exported or uploaded.
Native `wifi.csv`, `wifi.pcap`, and `observations.jsonl` remain unchanged. Derived
files and receipts live in the session's `.uploads` directory. Back up this
directory with the original logs: deleting receipts loses the local record of
previous submissions.

## Supported data

| Destination | Eligible data | Current implementation |
| --- | --- | --- |
| WiGLE | Wi-Fi observations with receiver coordinates and UTC | WiGLE 1.6 CSV; multipart HTTPS upload |
| Wardrift | Wi-Fi observations in WiGLE CSV | Raw CSV HTTPS upload; endpoint follows the upstream integration proposal |
| WDGWars | Wi-Fi CSV and separately qualified Meshtastic/MeshCore node observations | Asynchronous CSV jobs and signed mesh JSON requests |

WiGLE's current published CSV types do not include LoRa or mesh protocols.
Wardrift mesh ingestion could not be established from the available sources.
Neither destination receives raw LoRa packets, mesh message text, or disguised
mesh records in Wi-Fi columns. WDGWars mesh support has its own format and
identity requirements; recording a LoRa packet alone does not make it eligible.

The current uploader exports **Wi-Fi only** from the native WiGLE file. BLE is
documented by WiGLE but is outside this payload's capture/export scope.

## Wi-Fi CSV

The input reader accepts the native `WigleWifi-1.4` and `WigleWifi-1.6` headers
and writes the current 1.6 columns:

```text
MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,RCOIs,MfgrId,Type
```

Each output row preserves a Wi-Fi BSSID, advertised SSID when present, security
description, observation time, channel, measured frequency when supplied, RSSI,
and the receiver coordinates recorded by the native capture. Timestamps use UTC
`YYYY-MM-DD HH:MM:SS`. Frequency is MHz; altitude and accuracy are metres. HDOP is
not an accuracy measurement in metres and must not be placed in that column.

2.4, 5 and 6 GHz rows use the same format. A supplied frequency must match the
channel. A legacy file without frequency retains a blank frequency; channel
numbers overlap between bands, so the exporter never guesses a band. This
preserves native data but cannot recover missing band information. Confirm that
the installed Pager firmware includes frequency when validating tri-band output.

Invalid coordinates, timestamps, addresses, signal values and inconsistent
channel/frequency pairs are skipped with counts. Because native CSV has no
separate fix-valid flag, the exporter conservatively rejects `0,0` coordinates;
this also excludes a genuine observation at that exact location. It cannot
independently establish GPS fix age from CSV alone. The capture writer must attach
the valid receiver fix at observation time; a stale position must never be used
to fill missing data later.

CSV quoting preserves commas and quotes. Embedded line endings are escaped for
interchange. Original bytes remain in the original native file. Exports are
bounded to 512 KiB per artifact and at most 256 Wi-Fi artifacts per session;
larger sessions require offline splitting. Export preparation makes no uploads.

## WDGWars mesh eligibility

The exporter reads decoded observations and selects one representative sighting
per node: fewest known hops first, then strongest signal. All original sightings
remain in `observations.jsonl`. It tracks at most 4,096 eligible node identities;
additional nodes are counted as skipped. Requests contain at most 250 nodes.

Mesh records must have:

- A successfully decoded Meshtastic or MeshCore observation, without a known bad
  radio CRC. Unknown, encrypted, malformed and unsupported traffic stays local.
- A real protocol identity. Meshtastic uses its eight-hex-digit source number;
  zero and broadcast IDs are rejected. MeshCore requires the complete 32-byte
  public key and a successfully verified advertisement signature; the service's
  node ID is the first eight bytes of that key, rendered as 16 lowercase hex
  characters.
- An observed node role and a valid node-advertised position. A separate
  node-information packet from that identity in the same session can supply the
  role. Missing roles and missing advertised positions remain ineligible.
- A known hop count, real observation timestamp, and RSSI. For Meshtastic, known
  valid `hop_start` and `hop_limit` can establish the difference. Unknown hops
  are skipped because the reviewed server contract treats omitted hops as
  direct reception.

Meshtastic `hop_start:0` does not alone prove direct reception: older firmware
did not populate that field. Zero-start observations need explicit decoded
sender-bitfield evidence before the exporter treats their hop count as known;
otherwise they stay local. This follows the upstream
[MeshPacket field contract](https://github.com/meshtastic/protobufs/blob/master/meshtastic/mesh.proto).

Receiver GPS is never substituted for a node-advertised position. A relayed
packet does not establish that the originating node was near the Pager. A node's
advertised location is a claim by that node. MeshCore signature verification
checks the advertisement against its key; it does not prove that its claimed
coordinates are physically correct.

The interchange payload is:

```json
{"networks":[],"aircraft":[],"meshcore_nodes":[]}
```

Each eligible node carries `node_id`, `node_type`, `name`, `lat`, `lon`, `rssi`,
`first_seen`, `type`, `network`, and `path_hops`. `type` is the historical envelope
marker `MESHCORE` for both protocols. `network` explicitly distinguishes
`meshcore` from `meshtastic`. MeshCore also includes the actual `public_key`.
Unavailable names fall back to the identifier without claiming a human-readable
name was advertised. Message contents are excluded.

## Credentials and operator settings

The application's private configuration supplies the following structure:

```json
{
  "uploads": {
    "wigle": {
      "enabled": false,
      "auto": false,
      "api_name": "",
      "api_token": "",
      "donate": false
    },
    "wardrift": {"enabled": false, "auto": false, "api_key": ""},
    "wdgwars": {"enabled": false, "auto": false, "api_key": ""}
  }
}
```

Use service API credentials, not login passwords. Keep private configuration
outside the payload source directory, restrict it to the device owner, and omit
it from release archives and support bundles. UI key entry can be visible while
typing; normal status should show only whether credentials are configured.

The upload module never stores credentials in receipts, prints request headers,
or returns transport exception text. It validates TLS certificates and hostnames,
uses fixed HTTPS destinations, and refuses redirects. It ignores server-supplied
poll URLs and constructs the WDGWars polling route locally, preventing a response
from redirecting an API key to another host. WiGLE commercial-use donation is
separate and off unless `donate` is explicitly true.

## Transport and receipts

| Service | Request | Authentication and completion |
| --- | --- | --- |
| WiGLE | `POST https://api.wigle.net/api/v2/file/upload`, multipart field `file` | HTTP Basic API name/token; HTTP 200 plus JSON `success:true` means accepted for processing, not that every row has been imported |
| Wardrift | `POST https://wardrift.net/v1/ingest/signals`, raw `text/csv`, `X-File-Name` | `X-API-Key`; HTTP 200 plus JSON `accepted:true` or `duplicate:true` |
| WDGWars Wi-Fi | `POST https://wdgwars.pl/api/v2/upload-csv`, multipart field `file` | `X-API-Key`; HTTP 202 plus `ok:true` and `job_id` saves a pending job |
| WDGWars job | `GET https://wdgwars.pl/api/v2/upload-job/<id>` | Same API key; `status:done` finishes the job and retains import/rejection counts |
| WDGWars mesh | `POST https://wdgwars.pl/endpoint/upload/`, JSON envelope | `X-API-Key` plus HMAC; HTTP 200 plus `ok:true` records acceptance separately from per-node import counts |

WDGWars mesh signing uses compact JSON encoded as Base64, a random eight-byte
nonce rendered as 16 hex characters, and HMAC-SHA256 over the concatenated nonce
text and Base64 text. The API key's UTF-8 text is the HMAC key; do not hex-decode
it. The request body contains `data`, `nonce`, and `sig`.

For WiGLE, retain transaction IDs and inspect the service's upload history for
processing results. Its API exposes `GET /api/v2/file/transactions`. For WDGWars,
the mesh receipt retains `meshcore_imported`, `meshcore_already_seen`,
`meshcore_merged`, and `meshcore_rejected`; a successful HTTP response can still
contain zero imported nodes. CSV jobs retain available imported, captured,
updated, duplicate, missing-GPS and bad-row counts. Unknown receipts are not
declared successful.

The interactive and automatic uploader advances enabled destinations in rounds,
with one request per service per round, at most 32 requests, and a 240-second
processing budget. It prepares the export once, continues remaining chunks,
and polls saved jobs when they become due. Individual HTTPS requests receive
the remaining time budget, with at most 15 seconds for a socket operation and
45 seconds for the request. Responses are limited to 128 KiB. OS name resolution
and filesystem work are not forcibly interrupted by this deadline; the UI also
applies an outer process timeout. Checkpoints are written, flushed and synced
before POST and after the receipt. File hashes identify the precise exported
content. Receipt directories are separated by service and a one-way credential
fingerprint so changing accounts cannot reuse another account's upload state.

A saved pending job is polled without resubmitting its CSV. Polls wait at least
30 seconds after the previous response. Authentication failures block that account until the configured key
changes. A rate-limit response respects `Retry-After` up to one day; retries and
connections that failed before a request could be sent use bounded backoff and
at most three POST attempts. Waiting is split into intervals of at most 30
seconds. If the next attempt is beyond the remaining budget, the call returns
with the checkpoint pending rather than waiting or retrying early. A later
upload action resumes saved jobs and unsent chunks. Reaching the time or request
limit is reported as incomplete, never as a successful upload. The lower-level
`upload_session` API remains available for callers that need a single bounded
step of up to four requests without waiting.

If the connection is lost after a POST might have been sent, or the process
restarts with a `sending` checkpoint, the result becomes `uncertain`. It is not
automatically retried. Check the service history before manually reconciling
that checkpoint. Deleting or editing receipts can cause duplicate submissions;
there is deliberately no blind retry button for uncertain receipts. Original
logs remain available regardless of the outcome.

## Validation and source references

Host tests use synthetic fixtures and an injected fake transport. They cover
CSV band/timestamp/coordinate handling, mesh identity and location separation,
signature-envelope construction, opt-in, redirects, async recovery, credentials
redaction, rate limits, checkpoint failures, multi-chunk continuation, fair
service scheduling and deadline preservation. They perform no HTTP requests.
These tests establish local formatting and state behavior, not live acceptance
by any service. Real captures, device networking/TLS and service import receipts
still require hardware validation before publishing an upload-success claim.

Research checked 2026-11-17:

- [WiGLE CSV 1.6 specification](https://api.wigle.net/csvFormat.html) and
  [current API schema](https://api.wigle.net/swagger.json). The current Android
  client at `029eebfaa4ee6793129a5b33b6a9f949851fddd4` also handles 6 GHz in
  [Network.java](https://github.com/wiglenet/wigle-wifi-wardriving/blob/029eebfaa4ee6793129a5b33b6a9f949851fddd4/wiglewifiwardriving/src/main/java/net/wigle/wigleandroid/model/Network.java).
- [Kismet WiGLE export](https://kismetwireless.net/docs/readme/logging/wiglecsv/)
  requires an available GPS location for map-oriented observations.
- [Wardrift upload proposal for ESP32Marauder](https://github.com/justcallmekoko/ESP32Marauder/pull/1634),
  commit `0b6ac93f996beafb69070fe04b68656ce604c2d0`, documents the raw CSV route
  and acceptance flag. This is a primary integration source, not a complete
  service API specification. Wardrift's public page did not expose a readable
  mesh/API contract during this review. No claim is made about native LoRa
  ingestion, device signing, limits or live acceptance beyond this evidence.
- [WDGWars developer information](https://www.wdgwars.pl/press) documents API-key
  authentication, CSV and signed JSON uploads. Its first-party
  [Pager integration](https://github.com/LOCOSP/pineapple_pager_wdgwars/tree/f26b9c5b9585a6264f8cd55e4adcd32178975f8c)
  documents the separate synchronous v1 and asynchronous v2 CSV interfaces.
- [Heimdall mesh interchange](https://github.com/Yggdrasil-AI-labs/meshcore-to-wdgwars/blob/dfcd39b82e8b9e79cf1585da4185a37124705c2a/heimdall.py)
  and its [node-identity contract](https://github.com/Yggdrasil-AI-labs/meshcore-to-wdgwars/blob/dfcd39b82e8b9e79cf1585da4185a37124705c2a/docs/meshcore-node-id.md)
  explain the signed mesh envelope, distinct protocol namespaces and hop rules.

The upload/export code is an original implementation of these documented
interfaces. No code from these upstream uploaders was copied. In particular,
the reviewed LOCOSP Pager repository had no license file; its behavior was used
as an interface reference only.
