#!/usr/bin/env bash
# =============================================================================
# Speed-only test — non-destructive read benchmark + destructive write benchmark
# Use this when you've already verified capacity and just want speed numbers,
# or when you want a quick speed check before committing to the full test.
#
# Usage: sudo ./speed-only.sh /dev/sdX "Description" "claimed_speed"
# =============================================================================
set -uo pipefail
# NOTE: no 'set -e' so individual tool failures don't abort the script.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $# -lt 3 ]]; then
    echo "Usage: sudo $0 <device> <description> <claimed_speed>"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "$RESULTS_DIR"

DEVICE="$1"
DESCRIPTION="$2"
CLAIMED_SPEED="$3"

SAFE_DESC=$(echo "$DESCRIPTION" | tr ' /' '_-' | tr -cd '[:alnum:]_-')
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGFILE="${RESULTS_DIR}/${SAFE_DESC}_speed_${TIMESTAMP}.log"
> "$LOGFILE"

# Capture all output to log file and terminal
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "\n${BOLD}Speed Test: ${NC}$DESCRIPTION"
echo -e "${BOLD}Device:     ${NC}$DEVICE"
echo -e "${BOLD}Claimed:    ${NC}$CLAIMED_SPEED\n"

echo -e "${CYAN}--- hdparm buffered read ---${NC}"
hdparm -t "$DEVICE" 2>&1

echo -e "\n${CYAN}--- fio sequential read (30s, 1M blocks, direct I/O) ---${NC}"
fio --name=seq_read \
    --filename="$DEVICE" \
    --rw=read \
    --bs=1M \
    --size=1G \
    --numjobs=1 \
    --ioengine=libaio \
    --iodepth=32 \
    --direct=1 \
    --runtime=30 \
    --time_based \
    --group_reporting \
    --output-format=normal 2>&1

echo ""
echo -e "${YELLOW}Write tests will DESTROY DATA on $DEVICE.${NC}"
read -rp "Run write speed tests too? (YES/no): " DO_WRITE

if [[ "$DO_WRITE" == "YES" ]]; then
    echo -e "\n${CYAN}--- fio sequential write (30s, 1M blocks, direct I/O) ---${NC}"
    fio --name=seq_write \
        --filename="$DEVICE" \
        --rw=write \
        --bs=1M \
        --size=1G \
        --numjobs=1 \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --runtime=30 \
        --time_based \
        --group_reporting \
        --output-format=normal 2>&1

    echo -e "\n${CYAN}--- fio random 4K read (IOPS, 30s) ---${NC}"
    fio --name=rand_read_4k \
        --filename="$DEVICE" \
        --rw=randread \
        --bs=4k \
        --size=256M \
        --numjobs=1 \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --runtime=30 \
        --time_based \
        --group_reporting \
        --output-format=normal 2>&1

    echo -e "\n${CYAN}--- fio random 4K write (IOPS, 30s) ---${NC}"
    fio --name=rand_write_4k \
        --filename="$DEVICE" \
        --rw=randwrite \
        --bs=4k \
        --size=256M \
        --numjobs=1 \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --runtime=30 \
        --time_based \
        --group_reporting \
        --output-format=normal 2>&1
fi

# Strip ANSI color codes from log for clean reading
sed -i 's/\x1b\[[0-9;]*m//g' "$LOGFILE"

echo -e "\n${GREEN}${BOLD}Done. Compare results against claimed speed: $CLAIMED_SPEED${NC}"
echo "Log saved to: $LOGFILE"
