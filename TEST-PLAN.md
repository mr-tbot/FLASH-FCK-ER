# FLASH-FCK-ER — Test Plan

## Available Scripts

| Script | Purpose | Destructive? | Runtime |
|--------|---------|:------------:|---------|
| `find-device.sh` | List removable/external devices to identify the target | No | Instant |
| `quick-test-device.sh` | Fast capacity probe (f3probe) + speed benchmarks | **Yes** | ~5 min |
| `test-device.sh` | Full test: f3probe + sector-by-sector f3write/f3read + full speed suite | **Yes** | Hours |
| `speed-only.sh` | Read/write speed benchmarks only (hdparm + fio) | Write test is destructive | ~3 min |

---

## What We're Testing

### 1. Fake Capacity (most common scam)
The device controller firmware is reprogrammed to **report a false size** to the OS. A 32GB card might claim to be 512GB. Writes beyond the real capacity silently wrap around or corrupt, so your data is destroyed without warning.

### 2. Fake Speed (second most common)
The controller or label claims a speed class (e.g., U3 / A2 / 500MB/s) that the underlying NAND flash cannot deliver. A cheap card might claim 150MB/s but only deliver 15MB/s.

### 3. Fake Branding
Checking SMART data, serial numbers, and firmware strings for signs that the device is not what it claims to be.

---

## Test Phases (per device)

### Phase 0 — Device Identification
- `lsblk` — reported size, transport (USB/MMC)
- `hdparm -I` — firmware model/serial strings
- `smartctl -i` and `smartctl -A` — SMART attributes (SSDs)
- `dmesg` — kernel-reported device info

**Red flags:** Generic/missing model strings, nonsensical serial numbers, no SMART support on something claiming to be an SSD.

### Phase 1 — Quick Capacity Probe (`f3probe`)
- Low-level destructive probe that sends read/write patterns at strategic offsets
- Detects wrap-around / aliased sectors in **seconds to minutes**
- Good for a fast PASS/FAIL before committing to the full test
- Used by both `quick-test-device.sh` and `test-device.sh`

### Phase 2 — Full Capacity Verification (`f3write` + `f3read`)
- Writes unique data patterns to **every sector** of the device
- Reads it all back and checks for corruption
- This is the **gold standard** — no fake can hide from this
- Trade-off: takes hours for large claimed sizes, but fakes usually fail much sooner
- Only runs in `test-device.sh` (skipped in quick test)

### Phase 3 — Speed Benchmarks (`fio` + `hdparm`)
| Test | What it measures | Quick | Full |
|------|-----------------|:-----:|:----:|
| `hdparm -t` | Buffered sequential read (OS cache involved) | ✓ | ✓ |
| fio seq write 1M | Sustained sequential write throughput | ✓ (10s) | ✓ (30s) |
| fio seq read 1M | Sustained sequential read throughput | ✓ (10s) | ✓ (30s) |
| fio random 4K read | Random IOPS (realistic workload) | — | ✓ (30s) |
| fio random 4K write | Random write IOPS | — | ✓ (30s) |

All fio tests use **direct I/O** (bypass OS cache) for honest numbers.

---

## How To Run

### Step 1: Insert the device and identify it
```bash
sudo ./find-device.sh
```
Lists all removable/USB/MMC block devices with model, serial, transport, and recent kernel messages.

### Step 2a: Run the quick test (~5 minutes)
```bash
sudo ./quick-test-device.sh /dev/sdX "Brand Model Description" "claimed_size" "claimed_speed"
```
Fast f3probe + short speed benchmarks. Good for initial triage.

### Step 2b: Or run the full test (gold-standard, slow)
```bash
sudo ./test-device.sh /dev/sdX "Brand Model Description" "claimed_size" "claimed_speed"
```
Full f3probe + f3write/f3read + extended speed benchmarks. No fake survives this.

### Step 3: (Optional) Speed-only test
```bash
sudo ./speed-only.sh /dev/sdX "Brand Model Description" "claimed_speed"
```
Use when capacity is already verified and you just want speed numbers.

### Step 4: Review results
Reports are saved to `results/` with timestamps:
- `*_<timestamp>.txt` — full human-readable report
- `*_<timestamp>_summary.env` — machine-readable key=value summary
- `*_<timestamp>.log` — complete terminal output (ANSI stripped)

---

## What To Expect From Fakes

### Fake MicroSD / SD Cards
- `f3probe` will typically detect them instantly via sector aliasing
- `f3read` will show massive data corruption beyond the real size
- Speed is usually 10–30 MB/s regardless of printed speed class (U3, A2, etc.)
- SMART data unavailable — these are simple flash behind a basic controller
- Real capacity is typically 8–128GB behind multi-TB labels

### Fake External SSDs
- Unrealistic capacities (e.g., 16TB+ portable SSDs) are an instant red flag — legitimate consumer portables currently max out around 4TB
- Usually a small flash chip (64–256GB) behind a USB-SATA bridge with hacked firmware
- `f3probe` detects them within minutes
- Speed is often USB 2.0 class (5–40 MB/s) despite claiming USB 3.2 / NVMe speeds
- No valid SMART data, or generic controller strings instead of brand-specific firmware

### Fake USB Flash Drives / SSD Sticks
- Legitimate high-capacity USB SSD sticks exist (e.g., 1–2TB) but cost $100+
- Fakes are typically 32–128GB real capacity with modified controller firmware
- `f3probe` may or may not catch them — some sophisticated fakes require the full `f3write`/`f3read` test
- Check `smartctl` for brand-specific SMART attributes vs. generic junk
- Speed far below advertised is a strong secondary indicator

### General Red Flags
- Price is way too good (e.g., "2TB SSD" for $15–25)
- Capacity exceeds what's commercially available for the form factor
- Generic or nonsensical model/serial strings in `hdparm -I`
- No SMART support on something marketed as an SSD
- Speed below 50% of what's printed on the label

---

## Interpreting Results

| Outcome | Meaning |
|---------|---------|
| f3probe says "good" | Quick test passed (still run full test to be sure) |
| f3probe detects issues | **Confirmed fake capacity** |
| f3read shows data loss | **Confirmed fake capacity** (gold standard) |
| Sequential speed < 50% of claimed | **Fake speed rating** or very poor quality NAND |
| Random 4K < 1000 IOPS | Typical of cheap flash, not a genuine branded product |
| No SMART data on "SSD" | Likely a flash drive behind a USB bridge, not a real SSD |
| Reported size ≠ claimed size (>15% off) | Size mismatch — suspicious even if f3probe passes |
