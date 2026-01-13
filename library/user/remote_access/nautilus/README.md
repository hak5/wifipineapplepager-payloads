<h2 align="center">Nautilus</h2>
<p align="center">
<img alt="Nautilus Logo" width="200" src="www/nautilus_logo.png" />
</p>
<p align="center">
<i>Dive deep into your payloads</i>
</p>

<p align="center">
<img src="https://img.shields.io/badge/Platform-WiFi%20Pineapple%20Pager-00d4aa?style=flat-square" />
<img src="https://img.shields.io/badge/Version-1.5.3-blue?style=flat-square" />
<img src="https://img.shields.io/badge/Author-JustSomeTrout-purple?style=flat-square" />
</p>
<p align="center">
<a href="https://trello.com/b/AjPFVdmc/nautilus"><img src="https://img.shields.io/badge/Trello-Roadmap-0052CC?style=flat-square&logo=trello&logoColor=white" /></a>
</p>

```
    Title: Nautilus
    Author: JustSomeTrout (Trout / troot.)
    Developed for Firmware version 1.0.4
    Category: Remote Access / Utility
    Web-based payload launcher with GitHub integration.
    Control your Pager from any device on the network.
    Run payloads directly from GitHub - no installation required!
    *Humans were harmed in the making of this payload*
```

<p align="center">
<img width="3100" height="1359" alt="Nautilus Dashboard" src="https://github.com/user-attachments/assets/06e6860e-fd6f-4f24-beb9-1c6d09914403" />
</p>

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

---

## Overview

**Nautilus** transforms your WiFi Pineapple Pager into a web-accessible payload command center. Launch, monitor, and interact with payloads from your phone, laptop, tablet, or any device with a browser.

**Nautilus answers the question:**

> *Why install payloads when you can just run them?*

No more fumbling with D-pad navigation or manual file transfers. Just point, click, and watch the magic happen in real-time.

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

## New in 1.5.x

| Feature | Description |
|---------|-------------|
| **Background Service Mode** | Run Nautilus as a persistent background service that survives payload exit |
| **Foreground Mode** | Classic mode - payload stays running until you press B to exit |
| **Service Management** | Re-run payload to stop the service when running in background mode |
| **Virtual Button Panel** | Web-based D-pad and A/B buttons for payloads using `WAIT_FOR_INPUT` or `WAIT_FOR_BUTTON_PRESS` |
| **Smart Button Filtering** | Only allowed buttons are clickable - others are dimmed and disabled |
| **Shell on Any Interface** | ttyd shell now accessible from any network interface, not just br-lan |
| **Syntax Highlighting Fix** | Fixed View Source display for comments containing quotes |
| **Settings Panel** | Configure Nautilus preferences via the web UI settings button |
| **Auto Run Mode** | Skip the background/foreground prompt and auto-start with your preferred mode |

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

## Features

### Run Modes
- **Background Service**: Run Nautilus as a persistent service that survives payload exit (select Yes at startup)
- **Foreground Mode**: Classic mode where payload stays running until you press B to exit (select No at startup)
- **Service Management**: Re-run the payload to stop the service when running in background mode

### Core Functionality
- **Browse All Payloads**: Organized by category with collapsible sections
- **Search**: Find payloads instantly with live filtering
- **Payload Details**: View title, description, author, and version
- **View Source**: Inspect payload.sh content before running
- **One-Click Execution**: Run any payload with a single tap
- **Live Console**: Watch output stream in real-time with color support
- **Stop Control**: Abort running payloads at any time
- **Delete Payloads**: Remove local payloads directly from the web interface
- **Shell Terminal**: Full interactive shell access with PTY support
- **Virtual Button Panel**: D-pad and A/B buttons for payloads using `WAIT_FOR_INPUT`

### 🌐 GitHub Integration

Nautilus now has three payload sources accessible via tabs:

| Tab | Source | Description |
|-----|--------|-------------|
| **Local** | Your Pager | Payloads installed in `/root/payloads/user/` |
| **Merged** | GitHub Main | Official payloads from the hak5 repository |
| **PRs** | GitHub PRs | Open pull requests - test before they're merged! |

**Key Benefits:**
- **No Installation Required**: Run any payload from GitHub without copying files
- **Always Up-to-Date**: Merged tab shows the latest official payloads
- **Test New Payloads**: PRs tab lets you try community contributions before they're approved
- **Automatic Cleanup**: Downloaded payloads are removed after execution
- **Cached for Speed**: GitHub payload list is cached locally for fast browsing
- **Install to Local**: Save GitHub payloads permanently to your Pager with one click

### 📶 WiFi Client Mode

Configure your Pager's WiFi client connection directly from Nautilus:

- **Scan Networks**: Browse available WiFi networks with signal strength indicators
- **Connect**: Enter credentials and connect to any network
- **Disconnect**: Drop the current connection with one click
- **Toggle Client Mode**: Enable/disable the client interface

### Interactive Prompts
Nautilus intercepts and displays DuckyScript prompts in the web UI:

| Command | Web UI |
|---------|--------|
| `CONFIRMATION_DIALOG` | Yes/No modal dialog |
| `TEXT_PICKER` | Text input with default value |
| `NUMBER_PICKER` | Number input with default value |
| `IP_PICKER` | IP address input with validation |
| `MAC_PICKER` | MAC address input with validation |
| `PROMPT` | Generic text input |

Your response is sent back to the payload — no pager interaction required!

### Spinner Overlay
Payloads using `START_SPINNER` or `SPINNER` commands display a visual loading overlay in the web UI with a kill button to abort if needed.

### Security

Nautilus includes multiple layers of protection against web-based attacks:

| Protection | Description |
|------------|-------------|
| **Password Authentication** | Login required using root password with challenge-response |
| **Session Management** | Authenticated sessions with secure cookies |
| **Origin/Referer Validation** | Blocks cross-origin requests from malicious websites |
| **One-Time Tokens** | CSRF tokens required for payload execution |
| **Path Traversal Protection** | Prevents `/../` directory escape attacks in local and GitHub URLs |
| **GitHub URL Validation** | Only allows payloads from `wifipineapplepager-payloads` repositories |
| **Response Injection Protection** | Blocks shell metacharacters in user input |
| **Payload Path Validation** | Only executes files matching `/root/payloads/user/*/payload.sh` |
| **XSS Protection** | HTML escaping on all dynamic content including category names |

**Authentication Flow:**
1. Browser requests a challenge nonce from the server
2. Password is XOR-encrypted with SHA-256 hash of the nonce
3. Server decrypts and verifies against root password
4. Session cookie issued on successful authentication

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

## Requirements

### Dependencies

**Auto-Install**: On first run, Nautilus will prompt to install `uhttpd` if it's missing. Just confirm and it handles the rest.

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Your Device (Phone/Laptop/etc)                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Browser → http://172.16.42.1:8888                    │  │
│  │  ├── Tabs: Local | Merged | PRs                       │  │
│  │  ├── Sidebar: Browse payloads by category             │  │
│  │  ├── Console: Live SSE stream with colors             │  │
│  │  ├── Modals: Interactive prompts                      │  │
│  │  └── Spinner: Loading overlay with kill button        │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ HTTP/SSE
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  WiFi Pineapple Pager                                       │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  uhttpd (port 8888)                                   │  │
│  │  └── /cgi-bin/api.sh                                  │  │
│  │      ├── list       → JSON payload catalog (local)    │  │
│  │      ├── run        → Launch local payload + SSE      │  │
│  │      ├── run_github → Download & run GitHub payload   │  │
│  │      ├── stop       → Kill running payload + cleanup  │  │
│  │      ├── respond    → Send prompt response            │  │
│  │      └── refresh    → Rebuild payload cache           │  │
│  └───────────────────────────────────────────────────────┘  │
│                              │                              │
│            ┌─────────────────┼─────────────────┐            │
│            ▼                 ▼                 ▼            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ Local        │  │ GitHub API   │  │ GitHub Raw       │   │
│  │ /root/       │  │ Fetch tree   │  │ Download files   │   │
│  │ payloads/    │  │ structure    │  │ to /tmp/         │   │
│  └──────────────┘  └──────────────┘  └──────────────────┘   │
│                              │                              │
│                              ▼                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Wrapper Script (intercepts DuckyScript commands)     │  │
│  │  ├── LOG()              → Echo + real command         │  │
│  │  ├── LED()              → Echo + real command         │  │
│  │  ├── ALERT()            → Prompt via SSE (no pager)   │  │
│  │  ├── SPINNER()          → Overlay in web UI           │  │
│  │  ├── CONFIRMATION_DIALOG → Prompt via SSE             │  │
│  │  ├── TEXT_PICKER        → Prompt via SSE              │  │
│  │  ├── NUMBER_PICKER      → Prompt via SSE              │  │
│  │  ├── IP_PICKER          → Prompt via SSE              │  │
│  │  ├── MAC_PICKER         → Prompt via SSE              │  │
│  │  ├── WAIT_FOR_INPUT     → Button panel via SSE        │  │
│  │  └── WAIT_FOR_BUTTON_PRESS → Button panel via SSE     │  │
│  └───────────────────────────────────────────────────────┘  │
│                              │                              │
│                              ▼                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Your Payload (payload.sh)                            │  │
│  │  Runs with wrapper functions overriding real commands │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### GitHub Payload Flow

When you run a payload from the **Merged** or **PRs** tab:

1. **Fetch**: Nautilus downloads the payload folder from GitHub to `/tmp/`
2. **Execute**: The payload runs with the same wrapper as local payloads
3. **Stream**: Output streams to your browser in real-time
4. **Cleanup**: Temporary files are removed after execution (or on stop)

### Nautilus Payload Wrapper

When you run a payload through Nautilus, it doesn't run directly. Instead:

1. **Wrapper Created**: A temporary script defines wrapper functions for all DuckyScript commands
2. **Functions Exported**: `LOG`, `LED`, `CONFIRMATION_DIALOG`, `WAIT_FOR_INPUT`, etc. are exported to subshells
3. **Payload Sourced**: Your payload runs with wrapper functions taking precedence
4. **Output Captured**: All stdout/stderr streams to `/tmp/nautilus_output.log`
5. **SSE Polling**: The CGI backend polls the log file every 200ms for new lines
6. **Prompts Detected**: Special `[PROMPT:type]` markers in output trigger web modals
7. **Responses Returned**: User input writes to `/tmp/nautilus_response`, which the wrapper polls

### Response Flow

When a prompt appears in the web UI:

```
1. Payload calls: result=$(CONFIRMATION_DIALOG "Continue?")
2. Wrapper writes: [PROMPT:confirm] Continue?  → stderr → log file
3. CGI detects prompt marker, sends SSE event to browser
4. Browser shows modal, user clicks "Yes"
5. Browser calls: /api.sh?action=respond&response=1
6. CGI writes "1" to /tmp/nautilus_response
7. Wrapper's _wait_response() sees file, reads "1", returns it
8. CONFIRMATION_DIALOG echoes "1" to stdout
9. Payload receives: result="1"
```

### File-Based Communication

We use simple files instead of FIFOs for reliability:

| File | Purpose |
|------|---------|
| `/tmp/nautilus_output.log` | All payload output (stdout + stderr) |
| `/tmp/nautilus_response` | User's response to current prompt |
| `/tmp/nautilus_payload.pid` | PID of running wrapper process |
| `/tmp/nautilus_cache.json` | Pre-built payload catalog |
| `/tmp/nautilus_wrapper_$$.sh` | Generated wrapper script |

### Server-Sent Events (SSE)

Instead of polling for updates, Nautilus uses SSE for efficient real-time streaming.

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

## Installation

1. Copy the `nautilus` folder to your Pager:
   ```
   /root/payloads/user/general/nautilus/
   ```

2. The payload will appear in the Pager's menu under **Remote Access**.

### File Structure

```
nautilus/
├── payload.sh          # Main launcher (starts server, builds cache)
├── build_cache.sh      # Scans payloads, generates JSON catalog
├── README.md           # You are here
└── www/
    ├── index.html      # Single-file web UI (~50KB)
    ├── nautilus_logo.png
    └── cgi-bin/
        └── api.sh      # CGI backend (~30KB, handles everything)
```

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

## Usage

### Starting Nautilus

1. Navigate to **Remote Access → Nautilus** on your Pager
2. Press **A** to run
3. The display shows the server URL:
   ```
   Nautilus running
   http://172.16.42.1:8888
   Press B to stop
   ```
4. Open that URL in any browser on the same network
5. **Login**: Enter your Pager's root password when prompted

### Using the Web Interface

1. **Login**: Enter the root password (same as SSH/serial access)
2. **Choose Source**: Select a tab:
   - **Local**: Payloads installed on your Pager
   - **Merged**: Official payloads from GitHub (no installation needed!)
   - **PRs**: Open pull requests to test new community payloads
3. **Browse**: Payloads are organized by category in the left sidebar
4. **Search**: Type to filter payloads instantly
5. **Select**: Click a payload to see details
6. **Run**: Click the green **Run Payload** button
7. **Watch**: Output streams to the console in real-time
8. **Interact**: Prompts appear as modal dialogs — respond and continue
9. **Stop**: Click **Stop** or the X on the spinner to abort

### Running GitHub Payloads

When you run a payload from **Merged** or **PRs**:
- The payload downloads automatically to temporary storage
- Execution begins immediately with live console output
- All temp files are cleaned up after the payload finishes
- No files are permanently installed on your Pager

This is perfect for:
- **Testing new payloads** before deciding to install them
- **Running one-off utilities** you don't need permanently
- **Trying PR contributions** before they're merged

### Stopping Nautilus

- Press **B** on the Pager.

<p align="center">
<img width="600" height="4" alt="" src="https://github.com/user-attachments/assets/8560a6c9-b1f1-4eed-ac94-bd9e14d36ac5" />
</p>

## Supported DuckyScript Commands

### Output Commands (Displayed in Console)

| Command | Behavior |
|---------|----------|
| `LOG "message"` | Displays in console |
| `LOG green "message"` | Displays with color |
| `LED SETUP` | Shows LED status + executes on Pager |
| `ALERT "message"` | Shows alert modal (web UI only) |
| `ERROR_DIALOG "message"` | Shows error modal (web UI only) |

### Spinner Commands (Visual Overlay)

| Command | Behavior |
|---------|----------|
| `SPINNER "message"` | Shows spinning logo overlay with message |
| `START_SPINNER "message"` | Same as SPINNER |
| `SPINNER_STOP` | Hides the spinner overlay |
| `STOP_SPINNER` | Same as SPINNER_STOP |

The spinner overlay includes a kill button (X) to abort the payload if needed.

### Interactive Commands (Web Modals)

| Command | Modal Type | Returns |
|---------|------------|---------|
| `CONFIRMATION_DIALOG "msg"` | Yes/No buttons | `1` or `0` |
| `TEXT_PICKER "title" "default"` | Text input | User's text |
| `NUMBER_PICKER "title" "42"` | Number input | User's number |
| `IP_PICKER "title" "192.168.1.1"` | IP input | IP address |
| `MAC_PICKER "title" "00:11:22:33:44:55"` | MAC input | MAC address |
| `PROMPT "message"` | Text input | User's text |

### Button Input Commands (Virtual D-Pad)

| Command | Behavior | Returns |
|---------|----------|---------|
| `WAIT_FOR_INPUT` | Shows all buttons, waits for any press | `UP`, `DOWN`, `LEFT`, `RIGHT`, `A`, or `B` |
| `WAIT_FOR_BUTTON_PRESS UP` | Shows only UP button enabled | `UP` |
| `WAIT_FOR_BUTTON_PRESS A B` | Shows A and B buttons enabled | `A` or `B` |

The virtual button panel appears at the bottom of the console when a payload requests button input. Only allowed buttons are clickable - others are dimmed and disabled.

### Passthrough Commands

These commands execute on the Pager AND show status in the console:
- `LED` - Controls the LED and logs to console
- `LOG` - Logs to console and Pager display
- Real system commands work normally