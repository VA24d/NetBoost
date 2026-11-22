#!/bin/bash
# NetBoost Privileged Helper Script
# Handles operations requiring root privileges: pfctl, sysctl, networksetup, ARP/DNS flushing.

set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: netboost-helper.sh must be run with root privileges (sudo)." >&2
    exit 1
fi

ACTION="${1:-}"
shift || true

case "$ACTION" in
    status)
        echo "NetBoost Helper: Active (running as root)"
        sysctl net.inet.ip.forwarding
        pfctl -s info 2>/dev/null | head -n 5 || true
        ;;

    set-ip-forwarding)
        VALUE="${1:-1}"
        echo "Setting net.inet.ip.forwarding=$VALUE..."
        sysctl -w "net.inet.ip.forwarding=$VALUE"
        ;;

    pf-enable)
        echo "Enabling PF..."
        pfctl -e 2>/dev/null || true
        ;;

    pf-disable)
        echo "Disabling PF..."
        pfctl -d 2>/dev/null || true
        ;;

    pf-load-anchor)
        ANCHOR="${1:-netboost}"
        RULES_FILE="${2:-}"
        if [ -z "$RULES_FILE" ] || [ ! -f "$RULES_FILE" ]; then
            echo "Error: Rules file not specified or does not exist" >&2
            exit 2
        fi
        echo "Loading PF anchor '$ANCHOR' from $RULES_FILE..."
        pfctl -a "$ANCHOR" -f "$RULES_FILE"
        ;;

    pf-flush-anchor)
        ANCHOR="${1:-netboost}"
        echo "Flushing PF anchor '$ANCHOR'..."
        pfctl -a "$ANCHOR" -F all 2>/dev/null || true
        ;;

    set-mtu)
        DEVICE="${1:-}"
        MTU="${2:-1280}"
        if [ -z "$DEVICE" ]; then
            echo "Error: Device/Interface name required" >&2
            exit 2
        fi
        echo "Setting MTU for $DEVICE to $MTU..."
        networksetup -setMTU "$DEVICE" "$MTU"
        ;;

    flush-dns)
        echo "Flushing DNS cache..."
        dscacheutil -flushcache
        killall -HUP mDNSResponder 2>/dev/null || true
        echo "DNS cache flushed."
        ;;

    flush-arp)
        echo "Flushing ARP table..."
        arp -d -a 2>/dev/null || true
        echo "ARP table flushed."
        ;;

    disable-ipv6)
        SERVICE="${1:-}"
        if [ -z "$SERVICE" ]; then
            echo "Error: Service name required" >&2
            exit 2
        fi
        echo "Disabling IPv6 for service: $SERVICE..."
        networksetup -setv6off "$SERVICE"
        ;;

    reset-dns)
        SERVICE="${1:-}"
        if [ -z "$SERVICE" ]; then
            echo "Error: Service name required" >&2
            exit 2
        fi
        echo "Resetting DNS servers for service: $SERVICE to DHCP defaults..."
        networksetup -setdnsservers "$SERVICE" "Empty"
        ;;

    clean-proxies)
        SERVICE="${1:-}"
        if [ -z "$SERVICE" ]; then
            echo "Error: Service name required" >&2
            exit 2
        fi
        echo "Cleaning proxies for service: $SERVICE..."
        networksetup -setwebproxystate "$SERVICE" off 2>/dev/null || true
        networksetup -setsecurewebproxystate "$SERVICE" off 2>/dev/null || true
        networksetup -setautoproxystate "$SERVICE" off 2>/dev/null || true
        ;;

    order-services)
        if [ "$#" -lt 1 ]; then
            echo "Error: Ordered list of services required" >&2
            exit 2
        fi
        echo "Reordering network services..."
        networksetup -ordernetworkservices "$@"
        ;;

    *)
        echo "Usage: $0 {status|set-ip-forwarding [0|1]|pf-enable|pf-disable|pf-load-anchor <anchor> <file>|pf-flush-anchor <anchor>|set-mtu <device> <mtu>|flush-dns|flush-arp|disable-ipv6 <service>|reset-dns <service>|clean-proxies <service>|order-services <service1> <service2>...}" >&2
        exit 1
        ;;
esac

exit 0
