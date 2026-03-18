#!/usr/bin/env bash
# =============================================================================
# Storage Device Authenticity Tester
# Tests for fake capacity and fake speed on suspect storage devices.
#
# Usage: sudo ./test-device.sh /dev/sdX "Description" "claimed_size" "claimed_speed"
# Example: sudo ./test-device.sh /dev/sdb "SanDisk 512GB MicroSD" "512GB" "150MB/s"
#
# WARNING: The capacity tests (f3probe, f3write/f3read) are DESTRUCTIVE.
#          All data on the device WILL BE DESTROYED.
# =============================================================================
set -uo pipefail
# NOTE: we intentionally do NOT use 'set -e' because individual tool
# failures (f3write crash, fio error, etc.) must be caught and handled
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
MOUNT_POINT="/tmp/storage-check-mnt"

# ---------------------------------------------------------------------------
usage() {
    echo "Usage: sudo $0 <device> <description> <claimed_size> <claimed_speed>"
    echo ""
    echo "  device        : block device path, e.g. /dev/sdb"
    echo "  description   : human label, e.g. 'SanDisk 512GB MicroSD'"
    echo "  claimed_size  : advertised capacity, e.g. '512GB'"
    echo "  claimed_speed : advertised read speed, e.g. '150MB/s'"
    echo ""
    echo "WARNING: THIS TEST IS DESTRUCTIVE — all data on the device will be lost!"
    exit 1
}

# ---------------------------------------------------------------------------
log()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
hdr()  { echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}\n"; }

# ---------------------------------------------------------------------------
preflight_checks() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root (sudo)." >&2
        exit 1
    fi

    for cmd in f3probe f3write f3read fio hdparm lsblk smartctl; do
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
cleanup() {
    # Best-effort cleanup on exit (normal or abnormal)
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
unmount_device() {
    # Unmount all partitions of the device
    for part in "${DEVICE}"*; do
        if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^$part "; then
            log "Unmounting $part ..."
            umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true
        fi
    done
}

# ---------------------------------------------------------------------------
gather_device_info() {
    hdr "PHASE 0 — Device Information"

    log "lsblk output:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL,TRAN "$DEVICE" | tee -a "$REPORT"

    echo "" | tee -a "$REPORT"
    log "Kernel messages (last 30 lines for this device):"
    DEVBASE=$(basename "$DEVICE")
    dmesg | grep -i "$DEVBASE" | tail -30 | tee -a "$REPORT" || true

    echo "" | tee -a "$REPORT"
    log "SMART data (may not be available for SD cards):"
    smartctl -i "$DEVICE" 2>&1 | tee -a "$REPORT" || true
    smartctl -A "$DEVICE" 2>&1 | tee -a "$REPORT" || true

    echo "" | tee -a "$REPORT"
    log "hdparm identity:"
    hdparm -I "$DEVICE" 2>&1 | tee -a "$REPORT" || true
}

# ---------------------------------------------------------------------------
test_capacity_quick() {
    hdr "PHASE 1 — Quick Capacity Probe (f3probe)"
    log "f3probe performs a non-destructive (by default) low-level probe to"
    log "detect if the device controller lies about its capacity."
    log "This is FAST but can be fooled by sophisticated fakes."
    echo ""

    log "Running: f3probe --destructive --time-ops $DEVICE"
    warn "This WILL destroy data on $DEVICE"
    echo ""

    F3PROBE_OUT=$(f3probe --destructive --time-ops "$DEVICE" 2>&1) || true
    echo "$F3PROBE_OUT" | tee -a "$REPORT"

    if echo "$F3PROBE_OUT" | grep -qi "good"; then
        pass "f3probe says the device appears GENUINE"
        echo "F3PROBE_RESULT=PASS" >> "$SUMMARY"
    else
        fail "f3probe detected this device is FAKE / has problems"
        echo "F3PROBE_RESULT=FAIL" >> "$SUMMARY"
    fi
}

# ---------------------------------------------------------------------------
test_capacity_full() {
    hdr "PHASE 2 — Full Read/Write Capacity Test (f3write + f3read)"
    log "This writes data to every sector and reads it all back."
    log "It is SLOW but is the gold-standard for detecting fake capacity."
    log "For large claimed sizes this may take HOURS."
    echo ""

    # Create a filesystem so f3write can use it
    log "Creating temporary ext4 filesystem on ${DEVICE}..."
    mkfs.ext4 -F "$DEVICE" &>/dev/null || mkfs.ext4 -F "${DEVICE}1" &>/dev/null || {
        warn "Could not create filesystem; trying raw partition ${DEVICE}1"
    }

    mkdir -p "$MOUNT_POINT"
    mount "$DEVICE" "$MOUNT_POINT" 2>/dev/null || mount "${DEVICE}1" "$MOUNT_POINT" 2>/dev/null || {
        fail "Could not mount device for f3write/f3read test"
        echo "F3_FULL_RESULT=ERROR" >> "$SUMMARY"
        return
    }

    log "Running f3write (filling device with verification data)..."
    F3W_START=$(date +%s)
    # Temporarily disable pipefail so the pipeline doesn't short-circuit,
    # then use PIPESTATUS to get f3write's specific exit code.
    set +o pipefail
    f3write "$MOUNT_POINT" 2>&1 | tee -a "$REPORT"
    F3W_RC=${PIPESTATUS[0]}
    set -o pipefail
    F3W_END=$(date +%s)
    F3W_DURATION=$((F3W_END - F3W_START))

    # Count how many .h2w files were successfully written
    F3W_FILES_WRITTEN=$(find "$MOUNT_POINT" -name '*.h2w' 2>/dev/null | wc -l)
    # Estimate expected files: device size / ~4.7GB per file, minus filesystem overhead
    DEVICE_BYTES=$(lsblk -bndo SIZE "$DEVICE" 2>/dev/null | tr -d ' ' || echo 0)
    F3W_FILES_EXPECTED=$(( DEVICE_BYTES / 1073741824 / 5 + 1 ))  # rough estimate
    # Better: count from f3write output lines
    F3W_FILES_OK=$(grep -c 'OK!$' "$REPORT" 2>/dev/null || echo 0)

    if [[ $F3W_RC -ne 0 ]]; then
        warn "f3write exited with code $F3W_RC after ${F3W_DURATION}s"
        warn "Files successfully written: $F3W_FILES_WRITTEN (.h2w files on disk)"

        # Check if it was a "filled up" crash vs an early failure
        if grep -q 'Structure needs cleaning' "$REPORT" 2>/dev/null || \
           grep -q 'No space left on device' "$REPORT" 2>/dev/null || \
           grep -q 'Write failure' "$REPORT" 2>/dev/null; then
            warn "f3write stopped because the filesystem filled up (this is expected near 100%)"
            warn "This is NOT a sign of fake capacity — the ext4 overhead consumed the last portion."
            echo "F3W_STATUS=FILLED" >> "$SUMMARY"
        else
            fail "f3write crashed unexpectedly — check log for details"
            echo "F3W_STATUS=CRASHED" >> "$SUMMARY"
        fi
    else
        log "f3write completed successfully in ${F3W_DURATION}s"
        echo "F3W_STATUS=OK" >> "$SUMMARY"
    fi
    echo "F3W_FILES_WRITTEN=$F3W_FILES_WRITTEN" >> "$SUMMARY"

    echo "" | tee -a "$REPORT"

    # Run f3read if there are .h2w files to verify (even after partial f3write)
    if [[ "$F3W_FILES_WRITTEN" -gt 0 ]]; then
        log "Running f3read (verifying $F3W_FILES_WRITTEN written files)..."
        F3R_START=$(date +%s)
        F3R_RC=0
        F3R_OUT=$(f3read "$MOUNT_POINT" 2>&1) || F3R_RC=$?
        F3R_END=$(date +%s)
        F3R_DURATION=$((F3R_END - F3R_START))
        echo "$F3R_OUT" | tee -a "$REPORT"

        if [[ $F3R_RC -ne 0 ]]; then
            warn "f3read exited with code $F3R_RC after ${F3R_DURATION}s"
        else
            log "f3read completed in ${F3R_DURATION}s"
        fi

        # Parse f3read results
        DATA_LOST=$(echo "$F3R_OUT" | grep -iE 'data lost|corrupted' || true)

        if [[ -n "$DATA_LOST" ]] && echo "$DATA_LOST" | grep -qvE "^[[:space:]]*$"; then
            fail "DATA LOSS / CORRUPTION detected — device has FAKE capacity"
            echo "F3_FULL_RESULT=FAIL" >> "$SUMMARY"
        else
            pass "All written data verified successfully"
            echo "F3_FULL_RESULT=PASS" >> "$SUMMARY"
        fi
    else
        fail "No .h2w files written — f3write failed completely"
        echo "F3_FULL_RESULT=ERROR" >> "$SUMMARY"
    fi

    umount "$MOUNT_POINT" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
test_speed() {
    hdr "PHASE 3 — Speed Benchmarks"

    unmount_device

    log "--- Sequential Read (hdparm buffered) ---"
    hdparm -t "$DEVICE" 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    log "--- Sequential Read (hdparm cached) ---"
    hdparm -T "$DEVICE" 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    log "--- fio Sequential Write (1GB, bs=1M) ---"
    log "Live progress every 5 seconds:"
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
        --eta-newline=1 \
        --status-interval=5 \
        --output-format=normal 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    log "--- fio Sequential Read (1GB, bs=1M) ---"
    log "Live progress every 5 seconds:"
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
        --eta-newline=1 \
        --status-interval=5 \
        --output-format=normal 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    log "--- fio Random Read 4K (IOPS test) ---"
    log "Live progress every 5 seconds:"
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
        --eta-newline=1 \
        --status-interval=5 \
        --output-format=normal 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    log "--- fio Random Write 4K (IOPS test) ---"
    log "Live progress every 5 seconds:"
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
        --eta-newline=1 \
        --status-interval=5 \
        --output-format=normal 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"
}

# ---------------------------------------------------------------------------
generate_verdict() {
    hdr "VERDICT"

    echo -e "${BOLD}Device:${NC}         $DESCRIPTION"
    echo -e "${BOLD}Claimed Size:${NC}   $CLAIMED_SIZE"
    echo -e "${BOLD}Claimed Speed:${NC}  $CLAIMED_SPEED"
    echo ""

    source "$SUMMARY"

    FAKE=0
    WARNINGS=0

    echo -e "${BOLD}── Capacity ──${NC}"
    if [[ "${F3PROBE_RESULT:-UNKNOWN}" == "FAIL" ]]; then
        fail "f3probe detected fake capacity"
        FAKE=1
    elif [[ "${F3PROBE_RESULT:-UNKNOWN}" == "PASS" ]]; then
        pass "f3probe found no issues (quick probe)"
    fi

    if [[ "${F3_FULL_RESULT:-UNKNOWN}" == "FAIL" ]]; then
        fail "Full write/read test detected data loss — FAKE SIZE"
        FAKE=1
    elif [[ "${F3_FULL_RESULT:-UNKNOWN}" == "PASS" ]]; then
        pass "Full write/read test — all data verified"
        if [[ "${F3W_STATUS:-}" == "FILLED" ]]; then
            log "(f3write filled the device; filesystem ran out of space near 100% — this is normal)"
        fi
    elif [[ "${F3_FULL_RESULT:-UNKNOWN}" == "ERROR" ]]; then
        warn "Full write/read test could not run (f3write failed completely)"
        WARNINGS=$((WARNINGS + 1))
    fi

    if [[ "${F3W_FILES_WRITTEN:-0}" -gt 0 ]]; then
        log "f3write files on disk: ${F3W_FILES_WRITTEN}"
    fi

    echo ""
    echo -e "${BOLD}── Speed ──${NC}"
    echo "Review detailed speed results in: $REPORT"
    echo "Compare sequential read/write speeds against claimed: $CLAIMED_SPEED"

    echo ""
    echo -e "${BOLD}── Overall ──${NC}"
    if [[ $FAKE -eq 1 ]]; then
        echo ""
        echo -e "${RED}${BOLD}  ██████  DEVICE IS LIKELY FAKE  ██████${NC}"
    elif [[ $WARNINGS -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}${BOLD}  ⚠  INCONCLUSIVE — $WARNINGS warning(s). Review results manually.${NC}"
    else
        echo ""
        echo -e "${GREEN}${BOLD}  Device passed all tests — appears genuine${NC}"
    fi

    echo ""
    echo "Full report: $REPORT"
    echo "Full log:    $LOGFILE"
    echo "Summary:     $SUMMARY"
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

# Sanitize description for use in filenames
SAFE_DESC=$(echo "$DESCRIPTION" | tr ' /' '_-' | tr -cd '[:alnum:]_-')
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/${SAFE_DESC}_${TIMESTAMP}.txt"
SUMMARY="${RESULTS_DIR}/${SAFE_DESC}_${TIMESTAMP}_summary.env"
LOGFILE="${RESULTS_DIR}/${SAFE_DESC}_${TIMESTAMP}.log"

mkdir -p "$RESULTS_DIR"

{
    echo "============================================================"
    echo "Storage Authenticity Test Report"
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

# Capture ALL output (stdout + stderr) to .log file while still printing to terminal.
# We start logging after the confirmation prompt so it doesn't interfere with read.
start_logging() {
    exec > >(tee -a "$LOGFILE") 2>&1
}

preflight_checks

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          STORAGE AUTHENTICITY TESTER                    ║${NC}"
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

# Start logging all output to .log file
start_logging
log "Log file: $LOGFILE"

unmount_device
gather_device_info
test_capacity_quick
test_capacity_full
test_speed
generate_verdict

# Strip ANSI color codes from log file for clean reading
sed -i 's/\x1b\[[0-9;]*m//g' "$LOGFILE"
log "Full log saved to: $LOGFILE"
