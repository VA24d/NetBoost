#!/bin/bash
# NetBoost Privileged Helper Script
# Handles operations requiring root privileges: pfctl, sysctl, networksetup, ARP/DNS flushing.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: netboost-helper.sh must be run with root privileges (sudo)." >&2
    exit 1
fi

usage() {
    echo "Usage: $0 {status|set-ip-forwarding [0|1]|pf-enable|pf-disable|pf-load-anchor <anchor> <file>|pf-flush-anchor <anchor>|set-mtu <service-or-iface> <mtu>|flush-dns|flush-arp [ip]|disable-ipv6 <service>|reset-dns <service>|clean-proxies <service>|get-service-order|order-services <service1> [service2...]|isolate-relay <service>|restore-relay <service>|batch-autofix <service> [mtu]|help}" >&2
}

validate_safe_name() {
    local label="$1"
    local val="$2"
    if [ -z "$val" ]; then
        echo "Error: $label is required" >&2
        exit 2
    fi
    case "$val" in
        -*)
            echo "Error: Invalid $label '$val' (must not start with '-')" >&2
            exit 2
            ;;
    esac
}

validate_anchor() {
    local anchor="$1"
    if [ -z "$anchor" ] || ! [[ "$anchor" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Error: Invalid PF anchor name '$anchor'" >&2
        exit 2
    fi
}

validate_mtu() {
    local mtu="$1"
    if ! [[ "$mtu" =~ ^[0-9]+$ ]] || [ "$mtu" -lt 576 ] || [ "$mtu" -gt 1500 ]; then
        echo "Error: Invalid MTU '$mtu' (expected integer 576..1500)" >&2
        exit 2
    fi
}

validate_ipv4() {
    local ip="$1"
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Error: Invalid IPv4 address '$ip'" >&2
        exit 2
    fi
    local IFS='.'
    local octet
    for octet in $ip; do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            echo "Error: Invalid IPv4 octet '$octet' in '$ip'" >&2
            exit 2
        fi
    done
}

resolve_service_name() {
    local target="$1"
    # If caller passed a BSD interface (e.g. en0), resolve its macOS network service name when possible.
    if [[ "$target" =~ ^en[0-9]+$ ]]; then
        local resolved=""
        resolved="$(/usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$target" '
            /^\([0-9]+\) / {
                svc = $0
                sub(/^\([0-9]+\) /, "", svc)
            }
            /\(Hardware Port: .*Device: / {
                if ($0 ~ ("Device: " dev "\\)")) {
                    print svc
                    exit
                }
            }
        ' || true)"
        if [ -n "$resolved" ]; then
            echo "$resolved"
            return 0
        fi
    fi
    echo "$target"
}

ACTION="${1:-}"
shift || true

case "$ACTION" in
    status)
        echo "NetBoost Helper: Active (running as root)"
        /usr/sbin/sysctl net.inet.ip.forwarding
        /sbin/pfctl -s info 2>/dev/null | head -n 5 || true
        ;;

    set-ip-forwarding)
        VALUE="${1:-1}"
        if [ "$VALUE" != "0" ] && [ "$VALUE" != "1" ]; then
            echo "Error: Invalid IP forwarding value '$VALUE' (expected 0 or 1)" >&2
            exit 2
        fi
        echo "Setting net.inet.ip.forwarding=$VALUE..."
        /usr/sbin/sysctl -w "net.inet.ip.forwarding=$VALUE"
        ;;

    pf-enable)
        echo "Enabling PF..."
        /sbin/pfctl -e 2>/dev/null || true
        ;;

    pf-disable)
        echo "Disabling PF..."
        /sbin/pfctl -d 2>/dev/null || true
        ;;

    pf-load-anchor)
        ANCHOR="${1:-netboost}"
        RULES_FILE="${2:-}"
        validate_anchor "$ANCHOR"
        if [ -z "$RULES_FILE" ] || [ ! -f "$RULES_FILE" ]; then
            echo "Error: Rules file not specified or does not exist" >&2
            exit 2
        fi
        echo "Validating and loading PF anchor '$ANCHOR' from $RULES_FILE..."
        /sbin/pfctl -nf "$RULES_FILE"
        /sbin/pfctl -a "$ANCHOR" -f "$RULES_FILE"
        ;;

    pf-flush-anchor)
        ANCHOR="${1:-netboost}"
        validate_anchor "$ANCHOR"
        echo "Flushing PF anchor '$ANCHOR'..."
        /sbin/pfctl -a "$ANCHOR" -F all 2>/dev/null || true
        ;;

    set-mtu)
        DEVICE="${1:-}"
        MTU="${2:-1280}"
        validate_safe_name "Device/Service name" "$DEVICE"
        validate_mtu "$MTU"
        TARGET_SERVICE="$(resolve_service_name "$DEVICE")"
        echo "Setting MTU for '$TARGET_SERVICE' to $MTU..."
        /usr/sbin/networksetup -setMTU "$TARGET_SERVICE" "$MTU"
        ;;

    flush-dns)
        echo "Flushing DNS cache..."
        /usr/bin/dscacheutil -flushcache
        /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
        echo "DNS cache flushed."
        ;;

    flush-arp)
        TARGET_IP="${1:-}"
        if [ -n "$TARGET_IP" ]; then
            validate_ipv4 "$TARGET_IP"
            echo "Flushing ARP entry for $TARGET_IP..."
            /usr/sbin/arp -d "$TARGET_IP" 2>/dev/null || true
        else
            echo "Flushing ARP table..."
            /usr/sbin/arp -d -a 2>/dev/null || true
        fi
        echo "ARP cache flush complete."
        ;;

    disable-ipv6)
        SERVICE="${1:-}"
        validate_safe_name "Service name" "$SERVICE"
        echo "Disabling IPv6 for service: $SERVICE..."
        /usr/sbin/networksetup -setv6off "$SERVICE"
        ;;

    reset-dns)
        SERVICE="${1:-}"
        validate_safe_name "Service name" "$SERVICE"
        echo "Resetting DNS servers for service: $SERVICE to DHCP defaults..."
        /usr/sbin/networksetup -setdnsservers "$SERVICE" "Empty"
        ;;

    clean-proxies)
        SERVICE="${1:-}"
        validate_safe_name "Service name" "$SERVICE"
        echo "Cleaning proxies for service: $SERVICE..."
        /usr/sbin/networksetup -setwebproxystate "$SERVICE" off 2>/dev/null || true
        /usr/sbin/networksetup -setsecurewebproxystate "$SERVICE" off 2>/dev/null || true
        /usr/sbin/networksetup -setautoproxystate "$SERVICE" off 2>/dev/null || true
        ;;

    get-service-order)
        /usr/sbin/networksetup -listnetworkserviceorder
        ;;

    order-services)
        if [ "$#" -lt 1 ]; then
            echo "Error: Ordered list of services required" >&2
            exit 2
        fi
        for svc in "$@"; do
            validate_safe_name "Service name" "$svc"
        done
        echo "Reordering network services..."
        /usr/sbin/networksetup -ordernetworkservices "$@"
        ;;

    isolate-relay)
        SERVICE="${1:-}"
        validate_safe_name "Service name" "$SERVICE"
        echo "Isolating iCloud Private Relay on service: $SERVICE..."
        /usr/sbin/networksetup -setproxybypassdomains "$SERVICE" "*.mask.icloud.com" "*.mask-h2.icloud.com"
        ;;

    restore-relay)
        SERVICE="${1:-}"
        validate_safe_name "Service name" "$SERVICE"
        echo "Restoring iCloud Private Relay on service: $SERVICE..."
        /usr/sbin/networksetup -setproxybypassdomains "$SERVICE" "Empty"
        ;;

    batch-autofix)
        SERVICE="${1:-Wi-Fi}"
        MTU="${2:-1280}"
        validate_safe_name "Service name" "$SERVICE"
        validate_mtu "$MTU"
        TARGET_SERVICE="$(resolve_service_name "$SERVICE")"
        echo "Executing batch Auto-Fix (MTU $MTU, DNS, ARP) on '$TARGET_SERVICE'..."
        /usr/sbin/networksetup -setMTU "$TARGET_SERVICE" "$MTU"
        /usr/bin/dscacheutil -flushcache
        /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
        /usr/sbin/arp -d -a 2>/dev/null || true
        echo "Batch Auto-Fix complete."
        ;;

    help|-h|--help)
        usage
        exit 0
        ;;

    *)
        usage
        exit 1
        ;;
esac

exit 0
