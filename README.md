# fio_benchmark

A production-grade Bash script for comprehensive storage performance benchmarking using [fio](https://github.com/axboe/fio).

## Features

- **5 pre-defined test profiles** — sequential read/write, random read/write, and mixed random read/write
- **No `jq` dependency** — fio JSON output parsed with a single native `awk` pass
- **Formatted report** — IOPS, bandwidth (MiB/s), average latency, stddev, p99 latency, and CPU usage per test
- **Dry-run mode** — preview the exact `fio` commands without writing to disk
- **Interactive mode** — prompted input when no CLI arguments are provided
- **Defensive scripting** — strict mode (`set -Eeuo pipefail`), cleanup traps, write-permission checks, and fio timeouts
- **Zero external runtime dependencies** — requires only `fio`, `awk`, and Bash ≥ 4.4

## Requirements

| Tool | Minimum version |
|------|----------------|
| bash | 4.4            |
| fio  | 3.0            |
| awk  | any POSIX awk  |

## Installation

```bash
git clone https://github.com/9llo/fio_benchmark.git
cd fio_benchmark
chmod +x fio_benchmark.sh
```

## Usage

```
sudo ./fio_benchmark.sh [OPTIONS]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-t DEVICE` | Target block device or file | `/dev/sdb` |
| `-r RUNTIME` | Test runtime in seconds (per test) | `600` |
| `-n` | Dry-run — print fio commands without executing | — |
| `-v` | Show version and exit | — |
| `-h` | Show help and exit | — |

### Examples

```bash
# Benchmark /dev/nvme0n1 with default 600s per test
sudo ./fio_benchmark.sh -t /dev/nvme0n1

# Quick run with 60s per test
sudo ./fio_benchmark.sh -t /dev/sdb -r 60

# Preview commands without executing (no root required)
./fio_benchmark.sh -n -t /dev/sdb

# Interactive mode (no arguments)
sudo ./fio_benchmark.sh
```

## Test Profiles

| # | Name | Pattern | Block Size | Jobs | Size |
|---|------|---------|-----------|------|------|
| 1 | `seqread` | Sequential Read | 8k | 8 | 1G |
| 2 | `seqwrite` | Sequential Write | 32k | 4 | 2G |
| 3 | `randread` | Random Read | 8k | 16 | 1G |
| 4 | `randwrite` | Random Write | 64k | 8 | 512m |
| 5 | `randrw` | Random R/W (90% read) | 16k | 8 | 1G |

All tests run with `--direct=1`, `--ioengine=libaio`, and `--group_reporting`.

## Sample Output

```
=== FIO Benchmark v1.3.0 ===

  Running seqread              (bs=8k   jobs=8  size=1G  ) ... Done.
  Running seqwrite             (bs=32k  jobs=4  size=2G  ) ... Done.
  Running randread             (bs=8k   jobs=16 size=1G  ) ... Done.
  Running randwrite            (bs=64k  jobs=8  size=512m) ... Done.
  Running randrw               (bs=16k  jobs=8  size=1G  ) ... Done.

Detailed Storage Performance Report — fio v3+ | 2026-03-13T02:01:42
---------------------------------------------------------------------------------------------------------------------
  Device: /dev/sdb  |  Runtime per test: 120s
---------------------------------------------------------------------------------------------------------------------
Test                 | IOPS     | Bandwidth    | Avg Lat    | StdDev     | p99 Lat    | CPU (usr / sys)
---------------------------------------------------------------------------------------------------------------------
seqread              | 80300    | 627.3 MiB/s  | 0.09 ms    | 0.10 ms    | 0.28 ms    | 1.40% / 6.20%
seqwrite             | 45641    | 1426.3 MiB/s | 0.08 ms    | 0.09 ms    | 0.21 ms    | 1.67% / 7.70%
randread             | 83164    | 649.7 MiB/s  | 0.18 ms    | 0.16 ms    | 0.42 ms    | 0.55% / 2.93%
randwrite            | 23423    | 1464.0 MiB/s | 0.33 ms    | 0.22 ms    | 0.67 ms    | 0.80% / 2.01%
randrw               | 52067    | 813.6 MiB/s  | 0.30 ms    | 0.29 ms    | 0.43 ms    | 1.16% / 4.77%
---------------------------------------------------------------------------------------------------------------------
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | General error (missing deps, bad input, fio failure) |
| `130` | Interrupted (SIGINT / SIGTERM) |

## Safety Notes

- The script **requires root** to perform direct I/O on block devices. Dry-run (`-n`) does not require root.
- **Always verify the target device** (`-t`) before running. Direct I/O on a wrong device may cause data loss.
- A timeout of `3 × RUNTIME` seconds is enforced per fio job to prevent infinite hangs on unresponsive devices.

## License

MIT
