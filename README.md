# fio_benchmark

A production-grade Bash script for comprehensive storage performance benchmarking using [fio](https://github.com/axboe/fio).

## Features

- **9 pre-defined test profiles** — sequential (8k/32k/128k), random (4k/8k/64k), and mixed workloads
- **iodepth sweep** (`-s`) — runs randread at queue depths 1→128 to characterize saturation curve
- **RW-mix sweep** (`-m`) — runs randrw from 0%–100% writes in 10% steps to map write-penalty curve
- **Full latency distribution** — p50, p99, and p99.9 per test
- **IOPS/CPU efficiency ratio** — IOPS per 1% combined CPU; useful for hypervisor overhead comparison
- **Device fingerprint** — model, type (SSD/HDD), capacity, physical block size, and I/O scheduler in the report header
- **JSON and CSV output** (`-o json`/`-o csv`) — pipe-friendly; progress always goes to stderr
- **No `jq` dependency** — fio JSON output parsed with a single native `awk` pass
- **Dry-run mode** — preview every `fio` command without touching the disk
- **Interactive mode** — prompted input when no CLI arguments are provided
- **Defensive scripting** — strict mode (`set -Eeuo pipefail`), cleanup traps, write-permission checks, per-job timeouts

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
| `-s` | Run iodepth sweep (randread, bs=4k, iodepth 1→128) | — |
| `-m` | Run RW-mix sweep (randrw, bs=4k, 0%–100% writes) | — |
| `-o FORMAT` | Output format: `text`, `json`, `csv` | `text` |
| `-n` | Dry-run — print fio commands without executing | — |
| `-v` | Show version and exit | — |
| `-h` | Show help and exit | — |

### Examples

```bash
# Benchmark /dev/nvme0n1 with default 600s per test
sudo ./fio_benchmark.sh -t /dev/nvme0n1

# Quick run with 60s per test, plus iodepth and RW-mix sweeps
sudo ./fio_benchmark.sh -t /dev/sdb -r 60 -s -m

# Save full results as JSON (progress shown on stderr)
sudo ./fio_benchmark.sh -t /dev/nvme0n1 -r 120 -s -m -o json > results.json

# Export to CSV for spreadsheet analysis
sudo ./fio_benchmark.sh -t /dev/sdb -r 60 -o csv > results.csv

# Preview commands without executing (no root required)
./fio_benchmark.sh -n -t /dev/sdb -s -m

# Interactive mode (no arguments)
sudo ./fio_benchmark.sh
```

## Test Profiles

| # | Name | Pattern | Block Size | Jobs | Size |
|---|------|---------|-----------|------|------|
| 1 | `seqread` | Sequential Read | 8k | 8 | 1G |
| 2 | `seqwrite` | Sequential Write | 32k | 4 | 2G |
| 3 | `seq128kread` | Sequential Read (max BW) | 128k | 8 | 2G |
| 4 | `seq128kwrite` | Sequential Write (max BW) | 128k | 4 | 2G |
| 5 | `randread` | Random Read | 8k | 16 | 1G |
| 6 | `randwrite` | Random Write | 64k | 8 | 512m |
| 7 | `rand4kread` | 4K Random Read | 4k | 16 | 1G |
| 8 | `rand4kwrite` | 4K Random Write | 4k | 8 | 1G |
| 9 | `randrw` | Random R/W (90% read) | 16k | 8 | 1G |

All tests run with `--direct=1`, `--ioengine=libaio`, and `--group_reporting`.

### Optional sweeps

| Sweep | Flag | Pattern | Varies |
|-------|------|---------|--------|
| iodepth | `-s` | randread, bs=4k, numjobs=1 | iodepth: 1, 2, 4, 8, 16, 32, 64, 128 |
| RW-mix | `-m` | randrw, bs=4k, numjobs=8 | write %: 0, 10, 20 … 100 |

## Sample Output

### Text (default)

```
=== FIO Benchmark v1.5.0 ===

  Running seqread                (bs=8k    jobs=8  size=1G  ) ... Done.
  Running seqwrite               (bs=32k   jobs=4  size=2G  ) ... Done.
  Running seq128kread            (bs=128k  jobs=8  size=2G  ) ... Done.
  Running seq128kwrite           (bs=128k  jobs=4  size=2G  ) ... Done.
  Running randread               (bs=8k    jobs=16 size=1G  ) ... Done.
  Running randwrite              (bs=64k   jobs=8  size=512m) ... Done.
  Running rand4kread             (bs=4k    jobs=16 size=1G  ) ... Done.
  Running rand4kwrite            (bs=4k    jobs=8  size=1G  ) ... Done.
  Running randrw                 (bs=16k   jobs=8  size=1G  ) ... Done.

Detailed Storage Performance Report — fio v3+ | 2026-03-13T14:00:00
-------------------------------------------------------------------------------------------------------------------------------------------------------------------
  Device : /dev/nvme0n1
  Model  : Samsung SSD 980 PRO  |  Type: SSD/NVMe  |  Capacity: 953.87 GiB
  Phys block: 512 B  |  Scheduler: none  |  Runtime per test: 120s
-------------------------------------------------------------------------------------------------------------------------------------------------------------------
Test                   | IOPS     | Bandwidth    | Avg Lat    | StdDev     | p50 Lat    | p99 Lat    | p99.9 Lat  | CPU (usr / sys)    | IOPS/CPU
-------------------------------------------------------------------------------------------------------------------------------------------------------------------
seqread                | 80300    | 627.3 MiB/s  | 0.09 ms    | 0.10 ms    | 0.07 ms    | 0.28 ms    | 0.54 ms    | 1.40% / 6.20%      | 9797
seqwrite               | 45641    | 1426.3 MiB/s | 0.08 ms    | 0.09 ms    | 0.07 ms    | 0.21 ms    | 0.41 ms    | 1.67% / 7.70%      | 4945
seq128kread            | 8010     | 1001.2 MiB/s | 0.12 ms    | 0.06 ms    | 0.11 ms    | 0.19 ms    | 0.31 ms    | 0.90% / 3.40%      | 1885
seq128kwrite           | 6821     | 852.6 MiB/s  | 0.14 ms    | 0.08 ms    | 0.13 ms    | 0.22 ms    | 0.38 ms    | 0.80% / 3.10%      | 1751
randread               | 83164    | 649.7 MiB/s  | 0.18 ms    | 0.16 ms    | 0.14 ms    | 0.42 ms    | 0.89 ms    | 0.55% / 2.93%      | 23780
randwrite              | 23423    | 1464.0 MiB/s | 0.33 ms    | 0.22 ms    | 0.28 ms    | 0.67 ms    | 1.18 ms    | 0.80% / 2.01%      | 8430
rand4kread             | 321000   | 1253.9 MiB/s | 0.39 ms    | 0.21 ms    | 0.34 ms    | 0.72 ms    | 1.44 ms    | 2.10% / 9.30%      | 28407
rand4kwrite            | 180500   | 705.1 MiB/s  | 0.43 ms    | 0.25 ms    | 0.38 ms    | 0.91 ms    | 1.83 ms    | 1.90% / 8.10%      | 18050
randrw                 | 52067    | 813.6 MiB/s  | 0.30 ms    | 0.29 ms    | 0.25 ms    | 0.43 ms    | 0.87 ms    | 1.16% / 4.77%      | 8787
-------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

#### What to look for

| Metric | What it tells you |
|--------|------------------|
| **IOPS** | Raw throughput; compare rand4kread/write against vendor spec |
| **Bandwidth** | Saturated sequential throughput; seq128k shows true max bandwidth |
| **p50 Lat** | Typical latency experienced by the majority of I/Os |
| **p99 Lat** | Tail latency; high values indicate queue buildup or firmware jitter |
| **p99.9 Lat** | Worst-case outliers; critical for latency-sensitive services |
| **IOPS/CPU** | Efficiency; a sudden drop on a VM vs bare-metal hints at hypervisor overhead |

### iodepth sweep (`-s`)

```
  iodepth sweep (randread, bs=4k, numjobs=1):
    iodepth=1    ... Done.
    iodepth=2    ... Done.
    ...
    iodepth=128  ... Done.

iodepth Sweep — randread, bs=4k, numjobs=1
--------------------------------------------------------------
iodepth    | IOPS     | Bandwidth    | Avg Lat    | p99 Lat
--------------------------------------------------------------
1          | 12450    | 48.6 MiB/s   | 0.08 ms    | 0.12 ms
2          | 24800    | 96.9 MiB/s   | 0.08 ms    | 0.13 ms
4          | 48200    | 188.3 MiB/s  | 0.08 ms    | 0.15 ms
8          | 91000    | 355.5 MiB/s  | 0.09 ms    | 0.18 ms
16         | 168000   | 656.3 MiB/s  | 0.10 ms    | 0.22 ms
32         | 298000   | 1164.1 MiB/s | 0.11 ms    | 0.31 ms
64         | 420000   | 1640.6 MiB/s | 0.15 ms    | 0.52 ms
128        | 450000   | 1757.8 MiB/s | 0.28 ms    | 1.04 ms
--------------------------------------------------------------
```

#### What to look for

The iodepth sweep reveals the **queue depth saturation curve**: IOPS should climb steeply at low depths and plateau once the device's internal parallelism is fully utilized. The depth at which IOPS flattens out (here around 64–128) is the device's saturation point. Latency rising sharply before IOPS plateau indicates the queue is overloaded.

### RW-mix sweep (`-m`)

```
  RW-mix sweep (randrw, bs=4k, numjobs=8):
    write=0    % ... Done.
    write=10   % ... Done.
    ...
    write=100  % ... Done.

RW-mix Sweep — randrw, bs=4k, numjobs=8
----------------------------------------------------------------
Write %      | IOPS     | Bandwidth    | Avg Lat    | p99 Lat
----------------------------------------------------------------
0%           | 320000   | 1250.0 MiB/s | 0.20 ms    | 0.38 ms
10%          | 290000   | 1132.8 MiB/s | 0.22 ms    | 0.44 ms
20%          | 260000   | 1015.6 MiB/s | 0.25 ms    | 0.51 ms
30%          | 225000   | 878.9 MiB/s  | 0.29 ms    | 0.63 ms
50%          | 175000   | 683.6 MiB/s  | 0.37 ms    | 0.84 ms
70%          | 130000   | 507.8 MiB/s  | 0.50 ms    | 1.12 ms
100%         | 185000   | 722.7 MiB/s  | 0.43 ms    | 0.96 ms
----------------------------------------------------------------
```

#### What to look for

The RW-mix sweep maps the **write-penalty curve**. On SSDs with write amplification, IOPS typically drops as the write ratio increases, reaching a minimum around 50–70% writes before the write path becomes fully saturated and stabilizes. A steep penalty indicates a device sensitive to mixed workloads (relevant for databases and log-structured storage).

### JSON output (`-o json`)

```bash
sudo ./fio_benchmark.sh -t /dev/nvme0n1 -r 60 -s -o json > results.json
```

```json
{
  "timestamp": "2026-03-13T14:00:00",
  "device": {
    "path": "/dev/nvme0n1",
    "model": "SamsungSSD980PRO",
    "type": "SSD/NVMe",
    "capacity_gib": "953.87",
    "phys_block_bytes": "512",
    "scheduler": "none"
  },
  "runtime_secs": 60,
  "results": [
    {"test":"seqread","iops":80300,"bandwidth_mib":627.300,"lat_avg_ms":0.0900,"lat_std_ms":0.1000,"lat_p50_ms":0.0700,"lat_p99_ms":0.2800,"lat_p999_ms":0.5400,"cpu_usr_pct":1.40,"cpu_sys_pct":6.20,"iops_per_cpu":"9797"},
    ...
  ],
  "iodepth_sweep": [
    {"iodepth":1,"iops":12450,"bandwidth_mib":48.632,"lat_avg_ms":0.0800,"lat_p99_ms":0.1200},
    {"iodepth":2,"iops":24800,"bandwidth_mib":96.875,"lat_avg_ms":0.0800,"lat_p99_ms":0.1300},
    ...
  ]
}
```

### CSV output (`-o csv`)

```bash
sudo ./fio_benchmark.sh -t /dev/sdb -r 60 -o csv > results.csv
```

```
test,iops,bandwidth_mib,lat_avg_ms,lat_std_ms,lat_p50_ms,lat_p99_ms,lat_p999_ms,cpu_usr_pct,cpu_sys_pct,iops_per_cpu
seqread,80300,627.300,0.0900,0.1000,0.0700,0.2800,0.5400,1.40,6.20,9797
seqwrite,45641,1426.300,0.0800,0.0900,0.0700,0.2100,0.4100,1.67,7.70,4945
...
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
- **Progress output goes to stderr**; only the report (text/JSON/CSV) goes to stdout, so redirection to a file is clean.

## License

MIT
