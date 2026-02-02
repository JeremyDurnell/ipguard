# ipguard

A macOS network kill switch that monitors your public IP and cuts network adapters if it drifts from an expected value. Useful for ensuring traffic stays routed through a specific VPS/tunnel.

> **Note:** This is a personal project, maintained on a best-effort basis. No support is provided.

## How it works

ipguard watches for macOS network interface state changes via `SCDynamicStore`. When a change is detected, it checks your public IP against a known-good value. If they don't match, it kills the configured network interfaces. A menu bar plugin (SwiftBar) provides visual status and an acknowledgment action for when you intentionally move to a different network.

## Why ipguard?

Unlike traditional VPN kill switches that monitor for interface drops, ipguard takes a different approach:

- **Monitors actual egress IP** — Watches your real public IP, not just whether a VPN interface exists. Works with any tunnel technology (WireGuard, Tailscale, OpenVPN, etc.)
- **VPN-agnostic** — Doesn't care how the tunnel is implemented, just verifies the result
- **Works with exit nodes** — Monitors route integrity, not just VPN drops. Catches drift away from an expected egress point
- **Native Swift binary** — Compiles to native code, no runtime dependencies
- **No sudo required** — The core daemon runs as your user. The optional SwiftBar integration requires two permission grants (Accessibility, Automation)
- **Lightweight** — Background daemon + SwiftBar menu bar integration with 3-second polling
- **No firewall bloat** — No pf rules, no ipfw, no route deletion, no DNS blocking. Just watches the IP and disables the interface
- **Interface-specific isolation** — Targets specific adapters rather than blanket blocking everything
- **State machine architecture** — Clean PROTECTED → ISOLATED → UNPROTECTED transitions with acknowledgment flow
- **Sleep/wake aware** — Survives macOS sleep cycles, SCDynamicStore events trigger immediate checks on network reconnect
- **Synthetic test capability** — Inject fake IPs to verify the kill switch works without actually dropping your connection

## Prerequisites

- macOS with Xcode Command Line Tools installed (`xcode-select --install`)
- [SwiftBar](https://github.com/swiftbar/SwiftBar) installed (`brew install swiftbar`)
- [socat](https://brew.sh) installed (`brew install socat`) — used by the test script

## Build

```bash
make build
```

## Configure

Create a `.env` file in the project directory with your settings:

```bash
# Your VPS/tunnel public IP — the only IP the binary considers "good"
TRUSTED_IP=1.2.3.4

# Network interfaces to kill, comma-separated.
# en0 is always WiFi on macOS. Other interfaces vary by machine.
# Check yours with: networksetup -listallhardwareports
MANAGED_INTERFACES=en0,en9
```

You can use `.env.example` as a template:

```bash
cp .env.example .env
# Then edit .env with your values
```

**Note:** To change environment variables after installation, simply edit `.env` and run `./install.sh` again. The install script is idempotent and will reload the service with the updated values.

## Install

```bash
chmod +x install.sh
./install.sh
```

The install script validates that the binary exists and that environment variables are set, generates the launchd plist from the template, and loads the service. It is idempotent — safe to run multiple times.

## SwiftBar Plugin Setup

Copy the SwiftBar plugin script to your SwiftBar plugins folder (e.g., `~/swiftbar`):

```bash
cp ipguard.3s.swiftbar ~/swiftbar/
```

The filename controls the polling frequency. The format is `<name>.<interval><unit>.swiftbar`:
- `ipguard.3s.swiftbar` = refresh every 3 seconds
- `ipguard.2s.swiftbar` = refresh every 2 seconds
- `ipguard.5s.swiftbar` = refresh every 5 seconds

Rename the file in your plugins folder to adjust the refresh rate.

### Permissions

On first acknowledgment (ACK), SwiftBar will prompt for several macOS permissions:
- **Accessibility** — required to send commands to the socket
- **Automation** — required to control System Events

You'll need to **send the ACK action more than once** to trigger all permission prompts. Use the test script to trigger ISOLATED state (e.g., `TEST: 1`) and send ACKs through SwiftBar:

```bash
./test_ipguard.sh
# Then type: TEST: 1
# This will put the system in ISOLATED state, allowing you to test ACK from the menu bar
```

Each permission prompt will interrupt the ACK action, so click through each permission dialog and retry the ACK until all permissions are granted.

### Edge Case: Stale IP Data

If another process is keeping a persistent connection to `api.ipify.org` or `ifconfig.me` (the IP check endpoints), the IP check may return **stale cached data** from a previous network state. This can cause ipguard to miss an actual IP drift and fail to trigger an ISOLATED event. A common cause is having a browser tab open to one of these services.

## Verify

```bash
# Check the service is running
launchctl list com.ipguard

# Watch the logs
tail -f ~/.config/ipguard/ipguard.log

# Interactive test client
./test_ipguard.sh
```

## Test

The binary exposes a `TEST:` command over the socket that injects a synthetic IP, bypassing the actual public IP check. Useful for driving the state machine without changing your network:

```bash
# Simulate a bad IP (triggers kill)
echo "TEST: 1.1.1.1" | socat - UNIX-CONNECT:$HOME/.config/ipguard/ipguard.sock

# Simulate the good IP (triggers restore/protect)
echo "TEST: <your_TRUSTED_IP>" | socat - UNIX-CONNECT:$HOME/.config/ipguard/ipguard.sock

# Check state
echo "STATE" | socat - UNIX-CONNECT:$HOME/.config/ipguard/ipguard.sock

# Acknowledge (when ISOLATED)
echo "ACK" | socat - UNIX-CONNECT:$HOME/.config/ipguard/ipguard.sock
```

Or use the interactive test script:

```bash
./test_ipguard.sh          # interactive mode
./test_ipguard.sh watch    # poll state every 2 seconds
./test_ipguard.sh STATE    # one-shot state check
./test_ipguard.sh ACK      # one-shot acknowledge
```

## Uninstall

```bash
./install.sh uninstall
```

Stops and removes the launchd service. Logs are preserved at `~/.config/ipguard/ipguard.log`.

## State Machine

```
PROTECTED  ---(IP != TRUSTED_IP)---> ISOLATED
ISOLATED     ---(user ACK)--------> UNPROTECTED
ISOLATED     ---(IP == TRUSTED_IP)---> PROTECTED
ISOLATED     ---(bad IP resolves)-> UNPROTECTED (network recovered)
UNPROTECTED ---(IP == TRUSTED_IP)--> PROTECTED (ack cleared)
UNPROTECTED ---(IP != TRUSTED_IP)--> UNPROTECTED (no change)
```

**PROTECTED** — Public IP matches TRUSTED_IP. Network is up, everything is good.

**ISOLATED** — Public IP drifted or could not be determined. Network interfaces have been shut down. Waiting for user acknowledgment or for the IP to come back to TRUSTED_IP.

**UNPROTECTED** — Public IP does not match TRUSTED_IP, but either the user acknowledged it or the network recovered on its own. Traffic is flowing on a non-TRUSTED_IP. No action taken.

## WiFi behavior

WiFi (en0) is disabled only. The binary will turn the radio off during isolation, but it will **not** turn it back on during a restore. WiFi is easy to toggle back on in the menu bar, so it is left as a user-managed action. Other interfaces (i.e., ethernet,) are fully managed (disabled and restored) via `networksetup -setnetworkserviceenabled`.

## Files

| File                         | Purpose                                                                                 |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| `ipguard.swift`              | The main binary — state machine, network control, socket server, SCDynamicStore watcher |
| `test_ipguard.sh`            | Interactive test client for the socket interface                                        |
| `install.sh`                 | Idempotent install/uninstall script for the launchd service                             |
| `com.ipguard.plist.template` | Launchd plist template — `install.sh` fills in paths                                    |
| `makefile`                   | Build targets                                                                           |
| `.env.example`               | Example environment variable file for `make run`                                        |
