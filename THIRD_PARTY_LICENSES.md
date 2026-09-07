# Third-party software & attributions

FLASH-FCK-ER is MIT-licensed (see [LICENSE](LICENSE)). Its own runtime code is
pure Bash with no bundled third-party source, no binaries and no vendored
trees. It **depends on and orchestrates** the software below at run time — each
is installed by you from your own package manager, invoked as a separate
program, and retains its original license. Nothing here is a fork or
redistribution of upstream source; FLASH-FCK-ER ships glue code only. Invoking
a GPL program as a subprocess does not place this project under the GPL.

## Required runtime dependencies

### f3 (f3probe, f3write, f3read)
- **Project:** <https://github.com/AltraMayor/f3> · Michel Machado
- **License:** GPL-3.0-or-later
- **Role:** the actual fake-capacity detection engine. `f3probe --destructive` in the quick and full tests; `f3write`/`f3read` in the full test. Invoked as a subprocess; output parsed. **Massive thanks to the f3 project — it does the real work here.**

### fio
- **Project:** <https://github.com/axboe/fio> · Jens Axboe
- **License:** GPL-2.0
- **Role:** sequential and random 4K read/write benchmarking. Subprocess only.

### smartmontools (smartctl)
- **Project:** <https://www.smartmontools.org>
- **License:** GPL-2.0-or-later
- **Role:** reads SMART attributes where the device exposes them. Subprocess only.

### hdparm
- **Project:** <https://sourceforge.net/projects/hdparm/>
- **License:** BSD-style / mixed (see upstream)
- **Role:** buffered-read speed timing. Subprocess only.

### GNU bc
- **Project:** <https://www.gnu.org/software/bc/>
- **License:** GPL-3.0-or-later
- **Role:** all capacity and speed arithmetic. Subprocess only.

### util-linux (lsblk, findmnt, mountpoint, umount) and coreutils (mkfs.ext4 via e2fsprogs)
- **License:** GPL-2.0-or-later (util-linux); GPL-2.0-or-later (e2fsprogs)
- **Role:** device discovery, root-disk guard, and the destructive-test filesystem. Subprocess only.

## Trademarks
SanDisk, Kingston, Samsung and other brands named in the documentation are
trademarks of their respective owners, referenced only as examples of commonly
counterfeited products. No affiliation or endorsement is implied.
