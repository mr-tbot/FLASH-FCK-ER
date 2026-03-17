#!/usr/bin/env bash
# =============================================================================
# Quick helper: list all removable/external block devices to help identify
# which /dev/sdX your newly inserted device is.
# =============================================================================
set -euo pipefail

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Removable / External Block Devices"
echo "══════════════════════════════════════════════════════"
echo ""

lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL,TRAN,RM,HOTPLUG \
    | head -1

lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL,TRAN,RM,HOTPLUG \
    | tail -n +2 \
    | grep -E "usb|mmc|1[[:space:]]*$|1[[:space:]]+1" || true

echo ""
echo "Last 20 relevant kernel messages:"
dmesg | grep -iE "sd[a-z]|mmc|usb.*storage|new.*device|capacity|sector" | tail -20 || true
echo ""
