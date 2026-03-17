# FLASH-FCK-ER

**Fake flash storage detection toolkit.** Tests USB drives, SSDs, SD cards, and any block device for fake capacity, fake speed, and fake branding. Catches the Shenzhen specials before they eat your data.

```
  ██████  DEVICE IS LIKELY FAKE  ██████
```

---

## The Problem

Counterfeit storage is everywhere — Amazon, eBay, AliExpress, flea markets. A $5 chip gets re-flashed to report 2TB, slapped with a SanDisk label, and sold for $19.99. It "works" until you exceed the real capacity (usually 32–128GB), at which point your files silently corrupt with zero warning.

FLASH-FCK-ER detects:

- **Fake capacity** — controller firmware lying about device size (a 32GB chip claiming 2TB)
- **Fake speed** — labels claiming U3/A2/500MB/s when the NAND can barely push 15MB/s
- **Fake branding** — generic controllers with spoofed model strings pretending to be SanDisk/Kingston/Samsung

## Scripts

| Script | Purpose | Destructive? | Runtime |
|--------|---------|:------------:|---------|
| `find-device.sh` | List removable/external devices to identify the target | No | Instant |
| `quick-test-device.sh` | Fast capacity probe + speed benchmarks | **Yes** | ~5 min |
| `test-device.sh` | Full test: probe + sector-by-sector write/read + speed benchmarks | **Yes** | Hours (depends on claimed size) |
| `speed-only.sh` | Read/write speed benchmarks only | Write test is destructive | ~3 min |

> **WARNING: All tests except `find-device.sh` and read-only speed tests WILL DESTROY ALL DATA on the target device. Back up anything you care about first.**

---

## Supported Operating Systems

**Linux only.** All scripts rely on Linux-specific tools and interfaces (`/dev/sdX` block devices, `dmesg`, `lsblk`, `hdparm`, direct I/O via `libaio`). Tested on:

- Ubuntu / Debian
- Arch Linux
- Fedora / RHEL

Not compatible with macOS or Windows. WSL2 may work if the USB device is passed through to the Linux kernel, but this is untested.

---

## Quick Start

### 1. Install dependencies

```bash
# Debian / Ubuntu
sudo apt install f3 fio hdparm smartmontools

# Arch
sudo pacman -S f3 fio hdparm smartmontools

# Fedora
sudo dnf install f3 fio hdparm smartmontools
```

### 2. Plug in the suspect device and find it

```bash
sudo ./find-device.sh
```

Sample output:
```
══════════════════════════════════════════════════════
  Removable / External Block Devices
══════════════════════════════════════════════════════

NAME   SIZE TYPE FSTYPE MODEL                    SERIAL           TRAN RM HOTPLUG
sda    1.8T disk        USB SanDisk 3.2Gen1      0401deadbeef1234 usb   1       1
```

### 3. Run the quick test (~5 minutes)

```bash
sudo ./quick-test-device.sh /dev/sda "SanDisk 2TB Extreme MicroSD" "2TB" "250MB/s"
```

You'll be prompted to type `YES` to confirm destruction.

### 4. Or run the full test (gold-standard, but slow)

```bash
sudo ./test-device.sh /dev/sda "SanDisk 2TB Extreme MicroSD" "2TB" "250MB/s"
```

This writes unique data to **every sector**, reads it all back, and checks for corruption. No fake survives this test. Takes hours for large claimed sizes, but fakes usually fail fast.

### 5. Review results

Reports are saved to the `results/` directory with timestamps:

```
results/
  SanDisk_2TB_Extreme_MicroSD_quick_20260317_105514.txt      # Full report
  SanDisk_2TB_Extreme_MicroSD_quick_20260317_105514_summary.env  # Machine-readable summary
```

---

## Usage

### `find-device.sh`

```bash
sudo ./find-device.sh
```

Lists all removable/USB/MMC block devices with model, serial, transport, and recent kernel messages. Run this first to find which `/dev/sdX` your device landed on.

### `quick-test-device.sh`

```bash
sudo ./quick-test-device.sh <device> <description> <claimed_size> <claimed_speed>
```

| Argument | Example | Description |
|----------|---------|-------------|
| `device` | `/dev/sdb` | Block device path |
| `description` | `"Kingston 2TB SSD Stick"` | Human label (used in report filenames) |
| `claimed_size` | `"2TB"` | Advertised capacity (supports TB, GB, MB, TiB, GiB, MiB) |
| `claimed_speed` | `"500MB/s"` | Advertised read speed |

**Phases:**
1. Device identification (lsblk, dmesg, SMART, hdparm)
2. `f3probe` — quick capacity probe detecting sector aliasing
3. `fio` — 10-second sequential read/write benchmarks
4. Verdict — compares real vs claimed capacity + speed

### `test-device.sh`

```bash
sudo ./test-device.sh <device> <description> <claimed_size> <claimed_speed>
```

Same arguments as quick test. Adds:
- **Phase 2** — `f3write` + `f3read`: writes unique patterns to every sector, reads them all back. The gold-standard test that no fake can survive.
- **Extended speed benchmarks** — 30-second fio runs including random 4K IOPS tests.

### `speed-only.sh`

```bash
sudo ./speed-only.sh <device> <description> <claimed_speed>
```

Benchmarks only (no capacity testing). Includes:
- `hdparm` buffered read
- `fio` sequential read/write (30s each, direct I/O)
- `fio` random 4K read/write IOPS (optional, prompted)

---

## Test Phases Explained

### Phase 0 — Device Identification

Gathers fingerprint data: `lsblk` (size, transport, model), `hdparm -I` (firmware strings), `smartctl` (SMART attributes), `dmesg` (kernel-reported info).

**Red flags:** generic/missing model strings, nonsensical serial numbers, no SMART support on something claiming to be an SSD.

### Phase 1 — f3probe (Quick Capacity Probe)

Low-level destructive probe that sends read/write patterns at strategic offsets to detect sector aliasing (where writes past the real capacity wrap around to the beginning). Finishes in seconds to minutes.

### Phase 2 — f3write + f3read (Full Capacity Verification)

Writes unique data patterns to **every sector** of the device, then reads it all back. Any data corruption beyond the real capacity reveals the fake. This is the gold standard — no fake can hide from this.

### Phase 3 — Speed Benchmarks

| Test | Tool | What it measures |
|------|------|-----------------|
| Buffered seq read | `hdparm -t` | OS-cached sequential read throughput |
| Sequential write | `fio` (1M blocks, direct I/O) | Sustained sequential write |
| Sequential read | `fio` (1M blocks, direct I/O) | Sustained sequential read |
| Random 4K read | `fio` (4K blocks, direct I/O) | Random IOPS (realistic workload) |
| Random 4K write | `fio` (4K blocks, direct I/O) | Random write IOPS |

---

## Interpreting Results

### Verdict Output

Tests end with a clear verdict:

```
  ██████  DEVICE IS LIKELY FAKE  ██████
```
or
```
  Device passed all tests — appears genuine
```

### Summary File

The `.env` summary file is machine-readable:

```bash
F3PROBE_RESULT=FAIL
F3PROBE_REAL_SIZE='4.00 KB'
SEQ_WRITE_BW=5016KiB/s
SEQ_READ_BW=9983KiB/s
```

### What The Numbers Mean

| Outcome | Meaning |
|---------|---------|
| f3probe says "good" | Quick test passed — run full test for certainty |
| f3probe detects issues | **Confirmed fake capacity** |
| f3read shows data loss | **Confirmed fake** (gold standard) |
| Sequential speed < 50% of claimed | **Fake speed rating** or terrible NAND |
| Random 4K < 1000 IOPS | Cheap flash, not genuine branded product |
| No SMART data on "SSD" | Likely flash drive behind USB bridge, not a real SSD |
| Reported size vs claimed differs by >15% | Size mismatch — suspicious |

---

## What to Expect From Fakes

### Fake MicroSD / USB Flash Drives
- `f3probe` catches them instantly (sector aliasing)
- Real capacity typically 32–128GB behind "2TB" claims
- Speed: 10–30 MB/s regardless of printed speed class
- No SMART data

### Fake "32TB" SSDs
- 32TB is absurd for a consumer portable SSD
- Usually a 64–256GB chip behind a USB-SATA bridge with hacked firmware
- `f3probe` detects it within minutes
- Speed: USB 2.0 class (30–40 MB/s) despite claiming USB 3.2/NVMe speeds

### Fake Kingston / SanDisk Branded Sticks
- Legitimate 2TB USB SSDs exist (Kingston XS2000, ~$120+)
- Fakes are 32–128GB real capacity with modified firmware
- Check `smartctl` for brand-specific SMART attributes vs generic junk

---

## Dependencies

| Tool | Package | Purpose |
|------|---------|---------|
| `f3probe` | `f3` | Quick capacity probe |
| `f3write` / `f3read` | `f3` | Full sector-by-sector capacity verification |
| `fio` | `fio` | Flexible I/O benchmarking |
| `hdparm` | `hdparm` | Drive identity + buffered read speed |
| `smartctl` | `smartmontools` | SMART attribute inspection |
| `lsblk` | `util-linux` | Block device enumeration (pre-installed) |
| `bc` | `bc` | Arithmetic for size/speed comparisons |

---

## Output Files

All results are saved to `results/` with timestamped filenames:

| File | Contents |
|------|----------|
| `*_<timestamp>.txt` | Full human-readable report |
| `*_<timestamp>_summary.env` | Machine-readable key=value summary |
| `*_<timestamp>.log` | Complete terminal output (ANSI codes stripped) |

---

## License

Do whatever you want with it. Fakes deserve no mercy.
