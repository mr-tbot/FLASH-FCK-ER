#!/usr/bin/env bash
# =============================================================================
# Quick Storage Authenticity Tester
# Rapid check of capacity, speed, and authenticity in ~5 minutes.
#
# Usage: sudo ./quick-test-device.sh /dev/sdX "Description" "claimed_size" "claimed_speed"
# Example: sudo ./quick-test-device.sh /dev/sdc "SanDisk 2TB Extreme MicroSD" "2TB" "250MB/s"
#
# WARNING: THIS TEST IS DESTRUCTIVE — all data on the device will be lost!
#
# What it does (fast version of test-device.sh):
#   1. Device identification (lsblk, dmesg, smartctl, hdparm -I)
#   2. f3probe — quick capacity probe (detects sector aliasing in minutes)
#   3. Speed benchmarks — 10s each instead of 30s, seq read + write only
#   4. Verdict — compares real vs claimed capacity & speed
# =============================================================================
set -uo pipefail
# NOTE: we intentionally do NOT use 'set -e' because individual tool
# failures (f3probe crash, fio error, etc.) must be caught and handled
# gracefully so the script can continue to subsequent phases and verdict.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
QUICK_RUNTIME=10  # seconds per fio test

# ---------------------------------------------------------------------------
usage() {
    echo "Usage: sudo $0 <device> <description> <claimed_size> <claimed_speed>"
    echo ""
    echo "  device        : block device path, e.g. /dev/sdc"
    echo "  description   : human label, e.g. 'SanDisk 2TB Extreme MicroSD'"
    echo "  claimed_size  : advertised capacity, e.g. '2TB'"
    echo "  claimed_speed : advertised read speed, e.g. '250MB/s'"
    echo ""
    echo "This is a QUICK test (~5 min). For a thorough test use test-device.sh."
    echo "WARNING: THIS TEST IS DESTRUCTIVE — all data on the device will be lost!"
    exit 1
}

log()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
hdr()  {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
preflight_checks() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)." >&2
        exit 1
    fi

    for cmd in f3probe fio hdparm lsblk; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: Required command '$cmd' not found. Install it first." >&2
            exit 1
        fi
    done

    if [[ ! -b "$DEVICE" ]]; then
        echo "ERROR: '$DEVICE' is not a block device." >&2
        exit 1
    fi

    # Safety: refuse to operate on the root disk
    ROOT_DISK=$(lsblk -ndo PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
    if [[ "/dev/$ROOT_DISK" == "$DEVICE" ]]; then
        echo "ERROR: '$DEVICE' appears to be the root disk. Refusing." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
unmount_device() {
    for part in "${DEVICE}"*; do
        if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^$part "; then
            log "Unmounting $part ..."
            umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true
        fi
    done
}

# ---------------------------------------------------------------------------
# Parse a size string like "2TB", "512GB", "64MB" into bytes
parse_size_bytes() {
    local raw="$1"
    local num unit
    num=$(echo "$raw" | grep -oP '[\d.]+')
    unit=$(echo "$raw" | grep -oP '[A-Za-z]+')
    case "${unit^^}" in
        TB)  echo "$num * 1000000000000" | bc | cut -d. -f1 ;;
        TIB) echo "$num * 1099511627776" | bc | cut -d. -f1 ;;
        GB)  echo "$num * 1000000000" | bc | cut -d. -f1 ;;
        GIB) echo "$num * 1073741824" | bc | cut -d. -f1 ;;
        MB)  echo "$num * 1000000" | bc | cut -d. -f1 ;;
        MIB) echo "$num * 1048576" | bc | cut -d. -f1 ;;
        *)   echo "0" ;;
    esac
}

# Parse a speed string like "250MB/s" into MB/s number
parse_speed_mbs() {
    local raw="$1"
    local num unit
    num=$(echo "$raw" | grep -oP '[\d.]+' | head -1)
    unit=$(echo "$raw" | grep -oiP '[gmk]i?b' | head -1)
    case "${unit^^}" in
        GB|GIB) echo "$num * 1000" | bc ;;
        MB|MIB) echo "$num" ;;
        KB|KIB) echo "scale=2; $num / 1000" | bc ;;
        *)      echo "$num" ;;
    esac
}

# ---------------------------------------------------------------------------
gather_device_info() {
    hdr "PHASE 0 — Device Identification (quick)"

    log "lsblk:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL,TRAN "$DEVICE" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    REPORTED_SIZE_BYTES=$(lsblk -bndo SIZE "$DEVICE" 2>/dev/null | tr -d ' ' || echo "0")
    REPORTED_SIZE_HUMAN=$(lsblk -ndo SIZE "$DEVICE" 2>/dev/null | tr -d ' ' || echo "unknown")
    log "Reported size: $REPORTED_SIZE_HUMAN ($REPORTED_SIZE_BYTES bytes)"
    echo "REPORTED_SIZE_BYTES=$REPORTED_SIZE_BYTES" >> "$SUMMARY"
    echo "REPORTED_SIZE_HUMAN=$REPORTED_SIZE_HUMAN" >> "$SUMMARY"

    echo "" | tee -a "$REPORT"
    log "Kernel messages (last 15 lines):"
    DEVBASE=$(basename "$DEVICE")
    dmesg | grep -i "$DEVBASE" | tail -15 | tee -a "$REPORT" || true

    echo "" | tee -a "$REPORT"
    log "SMART identity (if available):"
    smartctl -i "$DEVICE" 2>&1 | tee -a "$REPORT" || true

    echo "" | tee -a "$REPORT"
    log "hdparm identity:"
    hdparm -I "$DEVICE" 2>&1 | tee -a "$REPORT" || true
}

# ---------------------------------------------------------------------------
test_capacity_quick() {
    hdr "PHASE 1 — Quick Capacity Probe (f3probe)"
    log "This detects if the controller lies about capacity via sector aliasing."
    log "Typically completes in 1-3 minutes."
    echo ""

    log "Running: f3probe --destructive --time-ops $DEVICE"
    warn "This WILL destroy data on $DEVICE"
    echo ""

    F3PROBE_START=$(date +%s)
    F3PROBE_OUT=$(f3probe --destructive --time-ops "$DEVICE" 2>&1) || true
    F3PROBE_END=$(date +%s)
    F3PROBE_DURATION=$((F3PROBE_END - F3PROBE_START))

    echo "$F3PROBE_OUT" | tee -a "$REPORT"
    log "f3probe completed in ${F3PROBE_DURATION}s"

    # Try to extract real vs announced size from f3probe output
    REAL_SIZE_LINE=$(echo "$F3PROBE_OUT" | grep -i "usable size" || echo "$F3PROBE_OUT" | grep -i "real.*size" || true)
    ANNOUNCED_SIZE_LINE=$(echo "$F3PROBE_OUT" | grep -i "announced" || true)

    if [[ -n "$REAL_SIZE_LINE" ]]; then
        log "f3probe detail: $REAL_SIZE_LINE"
    fi
    if [[ -n "$ANNOUNCED_SIZE_LINE" ]]; then
        log "f3probe detail: $ANNOUNCED_SIZE_LINE"
    fi

    if echo "$F3PROBE_OUT" | grep -qi "good"; then
        pass "f3probe says the device appears GENUINE"
        echo "F3PROBE_RESULT=PASS" >> "$SUMMARY"
    else
        fail "f3probe detected this device is FAKE / has problems"
        echo "F3PROBE_RESULT=FAIL" >> "$SUMMARY"

        # Try to extract the real usable size
        REAL_SIZE=$(echo "$F3PROBE_OUT" | grep -oP '[\d.]+ [GMKT]i?B' | tail -1 || true)
        if [[ -n "$REAL_SIZE" ]]; then
            fail "Real usable size appears to be: $REAL_SIZE"
            echo "F3PROBE_REAL_SIZE='$REAL_SIZE'" >> "$SUMMARY"
        fi
    fi
}

# ---------------------------------------------------------------------------
test_speed_quick() {
    hdr "PHASE 2 — Quick Speed Benchmarks (${QUICK_RUNTIME}s each)"

    unmount_device

    log "--- hdparm buffered read ---"
    HDPARM_OUT=$(hdparm -t "$DEVICE" 2>&1)
    echo "$HDPARM_OUT" | tee -a "$REPORT"
    HDPARM_SPEED=$(echo "$HDPARM_OUT" | grep -oP '[\d.]+ [MG]B/sec' | head -1 || true)
    if [[ -n "$HDPARM_SPEED" ]]; then
        log "hdparm sequential read: ${BOLD}$HDPARM_SPEED${NC}"
    fi
    echo "" | tee -a "$REPORT"

    log "--- fio Sequential Write (bs=1M, ${QUICK_RUNTIME}s, direct I/O) ---"
    log "Live progress:"
    SEQ_WRITE_OUT=$(fio --name=seq_write \
        --filename="$DEVICE" \
        --rw=write \
        --bs=1M \
        --size=1G \
        --numjobs=1 \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --runtime="$QUICK_RUNTIME" \
        --time_based \
        --group_reporting \
        --eta-newline=1 \
        --status-interval=3 \
        --output-format=normal 2>&1)
    echo "$SEQ_WRITE_OUT" | tee -a "$REPORT"
    SEQ_WRITE_BW=$(echo "$SEQ_WRITE_OUT" | grep -oP 'BW=\K[\d.]+ ?[MmGgKk]i?B/s' | head -1 || true)
    if [[ -n "$SEQ_WRITE_BW" ]]; then
        log "Sequential write speed: ${BOLD}$SEQ_WRITE_BW${NC}"
        echo "SEQ_WRITE_BW=$SEQ_WRITE_BW" >> "$SUMMARY"
    fi
    echo "" | tee -a "$REPORT"

    log "--- fio Sequential Read (bs=1M, ${QUICK_RUNTIME}s, direct I/O) ---"
    log "Live progress:"
    SEQ_READ_OUT=$(fio --name=seq_read \
        --filename="$DEVICE" \
        --rw=read \
        --bs=1M \
        --size=1G \
        --numjobs=1 \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --runtime="$QUICK_RUNTIME" \
        --time_based \
        --group_reporting \
        --eta-newline=1 \
        --status-interval=3 \
        --output-format=normal 2>&1)
    echo "$SEQ_READ_OUT" | tee -a "$REPORT"
    SEQ_READ_BW=$(echo "$SEQ_READ_OUT" | grep -oP 'BW=\K[\d.]+ ?[MmGgKk]i?B/s' | head -1 || true)
    if [[ -n "$SEQ_READ_BW" ]]; then
        log "Sequential read speed: ${BOLD}$SEQ_READ_BW${NC}"
        echo "SEQ_READ_BW=$SEQ_READ_BW" >> "$SUMMARY"
    fi
    echo "" | tee -a "$REPORT"
}

# ---------------------------------------------------------------------------
generate_quick_verdict() {
    hdr "QUICK VERDICT"

    echo -e "${BOLD}Device:${NC}         $DESCRIPTION"
    echo -e "${BOLD}Claimed Size:${NC}   $CLAIMED_SIZE"
    echo -e "${BOLD}Claimed Speed:${NC}  $CLAIMED_SPEED"
    echo ""

    source "$SUMMARY"

    FAKE=0
    WARNINGS=0

    # -- Capacity verdict --
    echo -e "${BOLD}── Capacity ──${NC}"
    if [[ "${F3PROBE_RESULT:-UNKNOWN}" == "FAIL" ]]; then
        fail "f3probe detected FAKE CAPACITY"
        if [[ -n "${F3PROBE_REAL_SIZE:-}" ]]; then
            fail "Real capacity: ~$F3PROBE_REAL_SIZE (claimed: $CLAIMED_SIZE)"
        fi
        FAKE=1
    elif [[ "${F3PROBE_RESULT:-UNKNOWN}" == "PASS" ]]; then
        pass "f3probe: capacity appears genuine"
        # Cross-check reported size vs claimed
        CLAIMED_BYTES=$(parse_size_bytes "$CLAIMED_SIZE")
        if [[ "$CLAIMED_BYTES" -gt 0 ]] && [[ "${REPORTED_SIZE_BYTES:-0}" -gt 0 ]]; then
            # Allow 8% tolerance (formatted capacity is always less than raw)
            THRESHOLD=$(echo "$CLAIMED_BYTES * 85 / 100" | bc)
            if [[ "$REPORTED_SIZE_BYTES" -lt "$THRESHOLD" ]]; then
                fail "Reported size ($REPORTED_SIZE_HUMAN) is significantly less than claimed ($CLAIMED_SIZE)"
                FAKE=1
            else
                pass "Reported size ($REPORTED_SIZE_HUMAN) matches claim ($CLAIMED_SIZE)"
            fi
        fi
    else
        warn "Capacity: could not determine (f3probe result unknown)"
        WARNINGS=$((WARNINGS + 1))
    fi

    echo ""
    echo -e "${BOLD}── Speed ──${NC}"

    # Parse claimed speed
    CLAIMED_MBS=$(parse_speed_mbs "$CLAIMED_SPEED")
    if [[ -n "${SEQ_READ_BW:-}" ]]; then
        # Extract numeric MB/s from fio output
        READ_NUM=$(echo "$SEQ_READ_BW" | grep -oP '[\d.]+' | head -1)
        READ_UNIT=$(echo "$SEQ_READ_BW" | grep -oiP '[gmk]i?b' | head -1)
        case "${READ_UNIT^^}" in
            GIB|GB) READ_MBS=$(echo "$READ_NUM * 1024" | bc 2>/dev/null || echo "$READ_NUM * 1000" | bc) ;;
            MIB|MB) READ_MBS="$READ_NUM" ;;
            KIB|KB) READ_MBS=$(echo "scale=2; $READ_NUM / 1024" | bc) ;;
            *) READ_MBS="$READ_NUM" ;;
        esac
        log "Measured sequential read:  ${BOLD}${SEQ_READ_BW}${NC}"
        if [[ -n "$CLAIMED_MBS" ]] && [[ $(echo "$READ_MBS < $CLAIMED_MBS * 0.5" | bc -l 2>/dev/null || echo "0") == "1" ]]; then
            fail "Sequential read ($SEQ_READ_BW) is less than 50% of claimed ($CLAIMED_SPEED) — SUSPICIOUS"
            WARNINGS=$((WARNINGS + 1))
        elif [[ -n "$CLAIMED_MBS" ]] && [[ $(echo "$READ_MBS < $CLAIMED_MBS * 0.75" | bc -l 2>/dev/null || echo "0") == "1" ]]; then
            warn "Sequential read ($SEQ_READ_BW) is below 75% of claimed ($CLAIMED_SPEED)"
            WARNINGS=$((WARNINGS + 1))
        else
            pass "Sequential read speed is in a reasonable range"
        fi
    fi

    if [[ -n "${SEQ_WRITE_BW:-}" ]]; then
        log "Measured sequential write: ${BOLD}${SEQ_WRITE_BW}${NC}"
    fi

    echo ""
    echo -e "${BOLD}── Overall ──${NC}"
    if [[ $FAKE -eq 1 ]]; then
        echo ""
        echo -e "${RED}${BOLD}  ██████  DEVICE IS LIKELY FAKE  ██████${NC}"
        echo ""
        echo "Run the full test for confirmation:"
        echo "  sudo ./test-device.sh $DEVICE \"$DESCRIPTION\" \"$CLAIMED_SIZE\" \"$CLAIMED_SPEED\""
    elif [[ $WARNINGS -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}${BOLD}  ⚠  SUSPICIOUS — $WARNINGS warning(s). Consider running the full test.${NC}"
        echo ""
        echo "  sudo ./test-device.sh $DEVICE \"$DESCRIPTION\" \"$CLAIMED_SIZE\" \"$CLAIMED_SPEED\""
    else
        echo ""
        echo -e "${GREEN}${BOLD}  Quick check passed — device appears genuine${NC}"
        echo -e "${GREEN}  For 100% confidence, run the full test (f3write+f3read).${NC}"
    fi

    echo ""
    echo "Report:  $REPORT"
    echo "Summary: $SUMMARY"
    echo "Log:     $LOGFILE"
}

# =============================================================================
# MAIN
# =============================================================================
if [[ $# -lt 4 ]]; then
    usage
fi

DEVICE="$1"
DESCRIPTION="$2"
CLAIMED_SIZE="$3"
CLAIMED_SPEED="$4"

# Sanitize description for filenames
SAFE_DESC=$(echo "$DESCRIPTION" | tr ' /' '_-' | tr -cd '[:alnum:]_-')
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/${SAFE_DESC}_quick_${TIMESTAMP}.txt"
SUMMARY="${RESULTS_DIR}/${SAFE_DESC}_quick_${TIMESTAMP}_summary.env"
LOGFILE="${RESULTS_DIR}/${SAFE_DESC}_quick_${TIMESTAMP}.log"

mkdir -p "$RESULTS_DIR"

{
    echo "============================================================"
    echo "Quick Storage Authenticity Test Report"
    echo "============================================================"
    echo "Date:           $(date)"
    echo "Device:         $DEVICE"
    echo "Description:    $DESCRIPTION"
    echo "Claimed Size:   $CLAIMED_SIZE"
    echo "Claimed Speed:  $CLAIMED_SPEED"
    echo "============================================================"
    echo ""
} > "$REPORT"

> "$SUMMARY"
> "$LOGFILE"

preflight_checks

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       QUICK STORAGE AUTHENTICITY TESTER (~5 min)       ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║  Device:  ${NC}$DEVICE"
echo -e "${BOLD}║  Label:   ${NC}$DESCRIPTION"
echo -e "${BOLD}║  Claimed: ${NC}$CLAIMED_SIZE @ $CLAIMED_SPEED"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${RED}${BOLD}  ⚠  ALL DATA ON $DEVICE WILL BE DESTROYED  ⚠${NC}"
echo ""
read -rp "Type YES to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# Start logging
exec > >(tee -a "$LOGFILE") 2>&1

OVERALL_START=$(date +%s)

unmount_device
gather_device_info
test_capacity_quick
test_speed_quick

OVERALL_END=$(date +%s)
OVERALL_DURATION=$((OVERALL_END - OVERALL_START))
log "Quick test completed in ${OVERALL_DURATION}s"

generate_quick_verdict

# Strip ANSI codes from log file
sed -i 's/\x1b\[[0-9;]*m//g' "$LOGFILE"
