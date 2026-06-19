# iocheck

`iocheck.sh` runs read and write tests with `fio` against a file inside a chosen mount point. It collects disk information first, checks TRIM/fstrim state, and then runs a small benchmark suite while keeping the full output in a report file.

## What it does

- Shows storage information before the tests start.
- Tries to identify whether the device is SATA or NVMe.
- Uses `smartctl`, `nvme-cli`, or `hdparm` when available.
- Checks `discard` mount options and `fstrim.timer`.
- Runs several `fio` workloads.
- Writes the full `fio` output to a report and prints a short summary per test in the terminal.

## Requirements

- `fio`
- `lsblk`, `findmnt`, `df`
- Optional: `smartctl`, `nvme`, `hdparm`, `systemctl`, `sudo`

On Debian/Ubuntu:

```bash
sudo apt install fio smartmontools nvme-cli hdparm
```

## Usage

```bash
./iocheck.sh --target /path/to/mount
```

Examples:

```bash
./iocheck.sh --target /mnt/ssd
./iocheck.sh --target /mnt/ssd --size 8G --runtime 120 --jobs 4
./iocheck.sh --target /mnt/ssd --device /dev/nvme0n1
./iocheck.sh --target /mnt/ssd --info-only
```

## Options

- `-t, --target DIR`: directory or mount point where the test file will be created.
- `--device DEV`: force the physical disk shown in the info section, for example `/dev/nvme0n1` or `/dev/sda`.
- `-s, --size SIZE`: `fio` test file size. Default: `4G`.
- `-r, --runtime SEC`: duration of each test in seconds. Default: `60`.
- `-j, --jobs N`: number of `fio` jobs. Default: `1`.
- `-d, --iodepth N`: queue depth. Default: `32`.
- `--report FILE`: report file. If omitted, the script creates `./fio-report-YYYYmmdd-HHMMSS.log`.
- `--keep-file`: do not delete the test file at the end.
- `--info-only`: show disk and TRIM/fstrim information only.
- `-h, --help`: show the built-in help.

## Tests

- Sequential write: `write` with `1M` blocks.
- Sequential read: `read` with `1M` blocks.
- Random write: `randwrite` with `4k` blocks.
- Random read: `randread` with `4k` blocks.
- Mixed random read/write: `randrw` with `70%` reads and `30%` writes.

For each test the script shows:

- the exact command that will run,
- a short explanation of the workload,
- a short summary with `IOPS`, `BW`, latency, and CPU usage.

The full `fio` output is stored in the report file.

## TRIM and fstrim

The script checks:

- whether the mount uses `discard`,
- whether `fstrim.timer` is active,
- whether the disk exposes `DISC-MAX` support.

If `fstrim.timer` is not enabled, the script prints these quick steps:

```bash
sudo systemctl enable --now fstrim.timer
systemctl status fstrim.timer
sudo fstrim -av
```

## Safety

- The script creates a file called `.fio-disk-check-testfile` inside the target.
- It does not write across the whole block device.
- You should still point it only at a mount or directory that belongs to the disk you want to measure.

## Reports

By default, reports are written in the current directory using a name like:

```bash
fio-report-20260619-144812.log
```

Git ignores these report files so benchmark results are not committed by accident.
