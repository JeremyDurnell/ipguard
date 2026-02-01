#!/bin/bash
# install.sh - Installs ipguard as a launchd service
#
# Usage:
#   ./install.sh            - Install and start the service
#   ./install.sh uninstall  - Stop and remove the service
#
# Prerequisites:
#   - Binary must be built first: make build
#   - Environment variables must be set in .env file:
#       TRUSTED_IP=<your_vps_ip>
#       MANAGED_INTERFACES=en0,en9

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/ipguard"
PLIST_TEMPLATE="$SCRIPT_DIR/com.ipguard.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/com.ipguard.plist"
LOG_PATH="$HOME/.config/ipguard/ipguard.log"
LABEL="com.ipguard"

# ─── Helpers ─────────────────────────────────────────────────────────────────
error() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "  $*"
}

# ─── Uninstall ───────────────────────────────────────────────────────────────
if [ "${1:-}" = "uninstall" ]; then
    echo "Uninstalling ipguard..."
    # Unload if running (ignore error if not loaded)
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    echo "Done. Log file preserved at $LOG_PATH"
    exit 0
fi

# ─── Validate ────────────────────────────────────────────────────────────────
echo "Installing ipguard..."

[ -f "$BINARY" ] || error "Binary not found at $BINARY. Run 'make build' first."
[ -f "$PLIST_TEMPLATE" ] || error "Plist template not found at $PLIST_TEMPLATE"

# Check env vars are set
[ -f .env ] && source .env || true

if [ -z "$TRUSTED_IP" ]; then
    error "TRUSTED_IP not set. Create a .env file with TRUSTED_IP=<your_vps_ip>"
fi
if [ -z "$MANAGED_INTERFACES" ]; then
    error "MANAGED_INTERFACES not set. Create a .env file with MANAGED_INTERFACES=en0,en9"
fi

info "TRUSTED_IP: $TRUSTED_IP"
info "MANAGED_INTERFACES: $MANAGED_INTERFACES"
info "Binary: $BINARY"
info "Log: $LOG_PATH"

# ─── Install ─────────────────────────────────────────────────────────────────

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_PATH")"

# Unload existing service if running (idempotent)
launchctl unload "$PLIST_DEST" 2>/dev/null || true

# Generate plist from template
sed \
    -e "s|__BINARY_PATH__|$BINARY|g" \
    -e "s|__LOG_PATH__|$LOG_PATH|g" \
    -e "s|__TRUSTED_IP__|$TRUSTED_IP|g" \
    -e "s|__MANAGED_INTERFACES__|$MANAGED_INTERFACES|g" \
    "$PLIST_TEMPLATE" > "$PLIST_DEST"

# Load the service
launchctl load "$PLIST_DEST"

echo "Done. Service started."
echo ""
echo "  Status: launchctl list $LABEL"
echo "  Logs:   tail -f $LOG_PATH"
echo "  Stop:   ./install.sh uninstall"
