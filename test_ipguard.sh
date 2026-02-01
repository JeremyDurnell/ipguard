#!/bin/bash
# test_ipguard.sh - Test client for ipguard socket interface
#
# Usage:
#   ./test_ipguard.sh STATE       - Query current state
#   ./test_ipguard.sh ACK         - Send acknowledgment
#   ./test_ipguard.sh watch       - Poll state every 2 seconds
#   ./test_ipguard.sh             - Interactive mode

SOCKET_PATH="$HOME/.config/ipguard/ipguard.sock"

send_command() {
    local cmd="$1"
    if [ ! -S "$SOCKET_PATH" ]; then
        echo "ERROR: Socket not found at $SOCKET_PATH"
        echo "Is ipguard running?"
        return 1
    fi
    local response
    response=$(echo "$cmd" | socat - UNIX-CONNECT:"$SOCKET_PATH" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to connect to socket"
        return 1
    fi
    echo "$response"
}

print_state() {
    local response
    response=$(send_command "STATE")
    [ $? -ne 0 ] && echo "$response" && return 1

    local state ip
    state=$(echo "$response" | cut -d: -f1)
    ip=$(echo "$response" | cut -d: -f2)

    case "$state" in
        PROTECTED)
            echo -e "\033[0;32m● PROTECTED\033[0m  IP: $ip"
            ;;
        ISOLATED)
            echo -e "\033[0;31m● ISOLATED\033[0m"
            ;;
        UNPROTECTED)
            echo -e "\033[0;33m● UNPROTECTED\033[0m  IP: $ip"
            ;;
        *)
            echo -e "\033[0;37m● UNKNOWN\033[0m  raw: $response"
            ;;
    esac
}

watch_mode() {
    echo "Watching state (Ctrl+C to stop)..."
    echo ""
    while true; do
        # Move cursor up and clear line on subsequent iterations
        if [ "${first_iteration:-}" != "true" ]; then
            echo -e "\033[A\033[2K"
        fi
        first_iteration=false
        print_state
        sleep 2
    done
}

interactive_mode() {
    echo "ipguard test client"
    echo "Commands: STATE, ACK, watch, quit"
    echo ""
    while true; do
        read -rp "> " input
        case "$input" in
            quit|exit|q)
                echo "Bye."
                exit 0
                ;;
            watch)
                watch_mode
                ;;
            STATE|ACK)
                local response
                response=$(send_command "$input")
                if [ $? -ne 0 ]; then
                    echo "$response"
                else
                    echo "  $response"
                fi
                ;;
            "")
                ;;
            *)
                # Send whatever they typed, let the binary handle it
                local response
                response=$(send_command "$input")
                if [ $? -ne 0 ]; then
                    echo "$response"
                else
                    echo "  $response"
                fi
                ;;
        esac
    done
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    STATE)
        print_state
        ;;
    ACK)
        echo "Sending ACK..."
        response=$(send_command "ACK")
        echo "Response: $response"
        ;;
    watch)
        watch_mode
        ;;
    "")
        interactive_mode
        ;;
    *)
        echo "Usage: $0 [STATE|ACK|watch]"
        echo "       $0            - interactive mode"
        exit 1
        ;;
esac