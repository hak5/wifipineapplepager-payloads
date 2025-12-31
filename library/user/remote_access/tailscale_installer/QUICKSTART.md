# Tailscale Quick Start Guide

## 12-Minute Setup

### Step 1: Install
```bash
cd /payloads/library/user/remote_access/tailscale_installer/
./payload.sh
```

The installer will automatically detect and install the latest stable version of Tailscale.

### Step 2: Configure
- Choose "Yes" for auto-start (recommended)
- Note the authentication URL in the logs

### Step 3: Authenticate
- Visit the URL on your phone/laptop
- Log in to Tailscale
- Approve the device

### Step 4: Get Your IP
```bash
tailscale ip -4
```

### Step 5: Connect
```bash
ssh root@100.x.y.z
```

## Common Commands

```bash
# Status
./manage.sh status

# Start/Stop
./manage.sh start
./manage.sh stop

# Reconnect
./manage.sh restart
```

## Troubleshooting

### Can't connect?
```bash
# Check status
tailscale status

# Restart service
/etc/init.d/tailscaled restart

# Reconnect
tailscale up
```

### Forgot your IP?
```bash
tailscale ip -4
```

### Need to re-authenticate?
```bash
./manage.sh reauth
```

## Uninstall
```bash
./manage.sh uninstall
```

## Support

- Full documentation: See README.md
- Tailscale docs: https://tailscale.com/kb/
- Admin console: https://login.tailscale.com/admin

