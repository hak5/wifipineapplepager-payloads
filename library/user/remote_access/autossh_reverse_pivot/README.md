# AutoSSH Reverse Pivot

Maintains a resilient reverse SSH tunnel for remote operator access. Optionally associates to WiFi before building the tunnel.

## Options
| Variable | Default | Description |
| --- | --- | --- |
| `AUTOSSH_HOST` | `example.com` | Remote SSH endpoint. |
| `AUTOSSH_USER` | `pager` | SSH username. |
| `AUTOSSH_PORT` | `22` | Remote SSH port. |
| `REMOTE_PORT` | `2222` | Remote bind port that forwards to the device. |
| `LOCAL_PORT` | `22` | Local port exposed through the tunnel. |
| `KEEPALIVE_INTERVAL` | `30` | SSH keep-alive interval in seconds. |
| `AUTOSSH_KEY` | `/root/.ssh/id_rsa` | Private key used for authentication. |
| `WIFI_INTERFACE` | `wlan0` | Interface used to associate to WiFi. |
| `WIFI_SSID` | `` | SSID to join (optional). |
| `WIFI_PASSWORD` | `` | Password for the SSID (optional). |
| `LOG_FILE` | `/root/loot/autossh-reverse-pivot/autossh.log` | Location of the autossh log. |

## Usage
1. Populate `AUTOSSH_HOST`, `AUTOSSH_USER`, and point `AUTOSSH_KEY` to a valid key on the device.
2. (Optional) Set `WIFI_SSID` and `WIFI_PASSWORD` to let the payload associate before tunneling.
3. Trigger the payload. A successful tunnel lights the LED green and keeps `autossh` running in the background. Logs live under `/root/loot/autossh-reverse-pivot/`.
