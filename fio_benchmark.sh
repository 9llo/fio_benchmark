#!/usr/bin/env bash
# =============================================================================
# fio_benchmark.sh — Storage performance benchmark using fio
#
# Requires: fio, bash (>= 4.4), awk
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly SCRIPT_VERSION="1.6.0"

readonly DEFAULT_TARGET="/dev/sdb"
readonly DEFAULT_RUNTIME=600
SEPARATOR=$(printf '%0.s-' {1..147})
readonly SEPARATOR
SWEEP_SEPARATOR=$(printf '%0.s-' {1..62})
readonly SWEEP_SEPARATOR
RWMIX_SEPARATOR=$(printf '%0.s-' {1..64})
readonly RWMIX_SEPARATOR

readonly SWEEP_DEPTHS=(1 2 4 8 16 32 64 128)
readonly RWMIX_WRITES=(0 10 20 30 40 50 60 70 80 90 100)

# ---------------------------------------------------------------------------
# Cleanup — runs on EXIT (normal or abnormal)
# ---------------------------------------------------------------------------
declare -g WORK_DIR=""

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'printf "\n" >&2; log_error "Interrupted."; exit 130' SIGINT SIGTERM

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { printf "[INFO]  %s\n" "$*" >&2; }
log_warn()  { printf "[WARN]  %s\n" "$*" >&2; }
log_error() { printf "[ERROR] %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat << EOF
Usage: sudo ${SCRIPT_NAME} [OPTIONS]

Storage performance benchmark using fio. Runs pre-defined tests:
  1. Sequential Read/Write   – bs=8k/32k
  2. Sequential Throughput   – bs=128k  (max BW / backup workload)
  3. Random Read/Write       – bs=8k/64k
  4. 4K Random Read/Write    – industry-standard benchmark unit
  5. Random R/W Mix          – bs=16k, 90% reads

Options:
  -t DEVICE   Target block device or file  (default: ${DEFAULT_TARGET})
  -r RUNTIME  Test runtime in seconds      (default: ${DEFAULT_RUNTIME})
  -s          Run iodepth sweep (randread, bs=4k, iodepth 1→128)
  -m          Run RW-mix sweep  (randrw,   bs=4k, 0%–100% writes)
  -o FORMAT   Output format: text, json, csv  (default: text)
  -n          Dry-run: print fio commands without executing
  -v          Show version and exit
  -h          Show this help message

Requires: fio, bash (>= 4.4), awk

Examples:
  sudo ${SCRIPT_NAME} -t /dev/nvme0n1
  sudo ${SCRIPT_NAME} -t /dev/sdb -r 60 -s -m
  sudo ${SCRIPT_NAME} -t /dev/sdb -o json > results.json
  ${SCRIPT_NAME} -n -t /dev/sdb

Exit codes:
  0   Success
  1   General error (missing deps, bad input, fio failure)
  130 Interrupted (SIGINT / SIGTERM)
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  for cmd in fio awk; do
    command -v "$cmd" &> /dev/null || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    log_error "Missing required commands: ${missing[*]}"
    log_error "Please install: ${missing[*]}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  TEST_TARGET="$DEFAULT_TARGET"
  RUNTIME="$DEFAULT_RUNTIME"
  DRY_RUN=false
  DO_SWEEP=false
  DO_RWMIX=false
  OUTPUT_FORMAT="text"

  local opt
  while getopts ":t:r:o:smnvh" opt; do
    case "$opt" in
      t) TEST_TARGET="$OPTARG" ;;
      r) RUNTIME="$OPTARG" ;;
      s) DO_SWEEP=true ;;
      m) DO_RWMIX=true ;;
      o)
        case "$OPTARG" in
          text | json | csv) OUTPUT_FORMAT="$OPTARG" ;;
          *)
            log_error "Unknown output format: ${OPTARG} (use text, json, or csv)"
            exit 1
            ;;
        esac
        ;;
      n) DRY_RUN=true ;;
      v)
        printf "%s version %s\n" "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit 0
        ;;
      h) usage ;;
      :)
        log_error "Option -${OPTARG} requires an argument."
        exit 1
        ;;
      ?)
        log_error "Unknown option: -${OPTARG}"
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
validate_inputs() {
  if [[ "$EUID" -ne 0 && "$DRY_RUN" == "false" ]]; then
    log_error "This script must be run as root (sudo)."
    exit 1
  fi

  if [[ "$DRY_RUN" == "false" ]]; then
    if [[ ! -e "$TEST_TARGET" ]]; then
      log_error "Target does not exist: $TEST_TARGET"
      exit 1
    fi
    if [[ ! -r "$TEST_TARGET" ]]; then
      log_error "Target is not readable: $TEST_TARGET"
      exit 1
    fi
    if [[ ! -w "$TEST_TARGET" ]]; then
      log_error "Target is not writable: $TEST_TARGET"
      exit 1
    fi
  fi

  if ! [[ "$RUNTIME" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Runtime must be a positive integer (seconds), got: $RUNTIME"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Interactive prompts (only when no CLI args were given)
# ---------------------------------------------------------------------------
interactive_prompts() {
  local input

  printf "Target device/file [%s]: " "$DEFAULT_TARGET"
  IFS= read -r input
  TEST_TARGET="${input:-$DEFAULT_TARGET}"

  printf "Runtime in seconds [%s]: " "$DEFAULT_RUNTIME"
  IFS= read -r input
  RUNTIME="${input:-$DEFAULT_RUNTIME}"

  printf "Dry-run only? (y/N): "
  IFS= read -r input
  case "${input,,}" in
    y | yes) DRY_RUN=true ;;
    *) DRY_RUN=false ;;
  esac

  printf "Run iodepth sweep (1→128)? (y/N): "
  IFS= read -r input
  case "${input,,}" in
    y | yes) DO_SWEEP=true ;;
    *) DO_SWEEP=false ;;
  esac

  printf "Run RW-mix sweep (0%%–100%% writes)? (y/N): "
  IFS= read -r input
  case "${input,,}" in
    y | yes) DO_RWMIX=true ;;
    *) DO_RWMIX=false ;;
  esac

  printf "Output format (text/json/csv) [text]: "
  IFS= read -r input
  case "${input,,}" in
    json | csv) OUTPUT_FORMAT="${input,,}" ;;
    *) OUTPUT_FORMAT="text" ;;
  esac
}

# ---------------------------------------------------------------------------
# Device fingerprint — populate DEV_* globals from sysfs
# ---------------------------------------------------------------------------
collect_device_info() {
  local dev_name="${TEST_TARGET##*/}"
  local sys_block="/sys/block/${dev_name}"

  # Walk up to the parent block device if given a partition
  if [[ ! -d "$sys_block" && -e "/sys/class/block/${dev_name}" ]]; then
    local parent
    parent=$(readlink "/sys/class/block/${dev_name}" 2>/dev/null \
      | awk -F/ '{ print $(NF-1) }' || true)
    [[ -n "${parent:-}" && -d "/sys/block/${parent}" ]] \
      && sys_block="/sys/block/${parent}"
  fi

  if [[ -d "$sys_block" ]]; then
    DEV_MODEL=$(tr -d '[:space:]' < "${sys_block}/device/model" 2>/dev/null \
      || printf "N/A")
    local rotational
    rotational=$(cat "${sys_block}/queue/rotational" 2>/dev/null || printf "1")
    [[ "$rotational" == "0" ]] && DEV_TYPE="SSD/NVMe" || DEV_TYPE="HDD (rotational)"
    DEV_SCHEDULER=$(awk 'match($0, /\[([^]]+)\]/, a) { print a[1] }' \
      "${sys_block}/queue/scheduler" 2>/dev/null || printf "N/A")
    DEV_PHY_BS=$(cat "${sys_block}/queue/physical_block_size" 2>/dev/null \
      || printf "N/A")
    local sectors
    sectors=$(cat "${sys_block}/size" 2>/dev/null || printf "0")
    DEV_SIZE_GIB=$(awk "BEGIN { printf \"%.2f\", ${sectors} * 512 / 1073741824 }")
  else
    DEV_MODEL="N/A"
    DEV_TYPE="N/A"
    DEV_SCHEDULER="N/A"
    DEV_PHY_BS="N/A"
    DEV_SIZE_GIB="N/A"
  fi
}

# ---------------------------------------------------------------------------
# Parse fio JSON output — single awk pass, no jq required
#
# Outputs 11 lines:
#   IOPS | BW(MiB/s) | RdLat(ms) | WrLat(ms) | RdStd(ms) | WrStd(ms) | p50(ms) | p99(ms) | p99.9(ms) | usr% | sys%
# ---------------------------------------------------------------------------
parse_fio_metrics() {
  local json_file="$1"

  awk '
  BEGIN {
    section=""; subsec=""; in_perc=0
    r_iops=0;  w_iops=0;  r_iops_set=0; w_iops_set=0
    r_bw=0;    w_bw=0;    r_bw_set=0;   w_bw_set=0
    r_mean=0;  w_mean=0;  r_mean_set=0; w_mean_set=0
    r_std=0;   w_std=0;   r_std_set=0;  w_std_set=0
    r_p50=0;   w_p50=0;   r_p50_set=0;  w_p50_set=0
    r_p99=0;   w_p99=0;   r_p99_set=0;  w_p99_set=0
    r_p999=0;  w_p999=0;  r_p999_set=0; w_p999_set=0
    usr=0;     sys=0;     usr_set=0;    sys_set=0
  }

  # ── Section / subsection tracking ─────────────────────────────────────────
  /"read"[[:space:]]*:[[:space:]]*\{/    { section="read";  subsec=""; in_perc=0 }
  /"write"[[:space:]]*:[[:space:]]*\{/   { section="write"; subsec=""; in_perc=0 }
  /"clat_ns"[[:space:]]*:[[:space:]]*\{/ { subsec="clat_ns" }
  /"slat_ns"[[:space:]]*:[[:space:]]*\{/ { subsec="slat_ns" }
  /"lat_ns"[[:space:]]*:[[:space:]]*\{/  { subsec="lat_ns"  }
  /"percentile"[[:space:]]*:[[:space:]]*\{/ { in_perc=1 }

  # Close brace: unwind the innermost tracked scope
  /^[[:space:]]*\}/ {
    if (in_perc)           { in_perc=0 }
    else if (subsec != "") { subsec="" }
  }

  # ── Value extraction ───────────────────────────────────────────────────────
  /"iops"[[:space:]]*:/ && !in_perc {
    if (match($0, /:[[:space:]]*([0-9]+\.?[0-9]*)/, v)) {
      if (section=="read"  && !r_iops_set) { r_iops=v[1]+0; r_iops_set=1 }
      if (section=="write" && !w_iops_set) { w_iops=v[1]+0; w_iops_set=1 }
    }
  }

  /"bw_bytes"[[:space:]]*:/ {
    if (match($0, /:[[:space:]]*([0-9]+)/, v)) {
      if (section=="read"  && !r_bw_set) { r_bw=v[1]+0; r_bw_set=1 }
      if (section=="write" && !w_bw_set) { w_bw=v[1]+0; w_bw_set=1 }
    }
  }

  /"mean"[[:space:]]*:/ && subsec=="clat_ns" && !in_perc {
    if (match($0, /:[[:space:]]*([0-9]+\.?[0-9]*)/, v)) {
      if (section=="read"  && !r_mean_set) { r_mean=v[1]+0; r_mean_set=1 }
      if (section=="write" && !w_mean_set) { w_mean=v[1]+0; w_mean_set=1 }
    }
  }

  /"stddev"[[:space:]]*:/ && subsec=="clat_ns" && !in_perc {
    if (match($0, /:[[:space:]]*([0-9]+\.?[0-9]*)/, v)) {
      if (section=="read"  && !r_std_set) { r_std=v[1]+0; r_std_set=1 }
      if (section=="write" && !w_std_set) { w_std=v[1]+0; w_std_set=1 }
    }
  }

  /"50\.000000"[[:space:]]*:/ && in_perc {
    if (match($0, /:[[:space:]]*([0-9]+)/, v)) {
      if (section=="read"  && !r_p50_set) { r_p50=v[1]+0; r_p50_set=1 }
      if (section=="write" && !w_p50_set) { w_p50=v[1]+0; w_p50_set=1 }
    }
  }

  /"99\.000000"[[:space:]]*:/ && in_perc {
    if (match($0, /:[[:space:]]*([0-9]+)/, v)) {
      if (section=="read"  && !r_p99_set) { r_p99=v[1]+0; r_p99_set=1 }
      if (section=="write" && !w_p99_set) { w_p99=v[1]+0; w_p99_set=1 }
    }
  }

  /"99\.900000"[[:space:]]*:/ && in_perc {
    if (match($0, /:[[:space:]]*([0-9]+)/, v)) {
      if (section=="read"  && !r_p999_set) { r_p999=v[1]+0; r_p999_set=1 }
      if (section=="write" && !w_p999_set) { w_p999=v[1]+0; w_p999_set=1 }
    }
  }

  /"usr_cpu"[[:space:]]*:/ {
    if (!usr_set && match($0, /:[[:space:]]*([0-9]+\.?[0-9]*)/, v)) {
      usr=v[1]+0; usr_set=1
    }
  }

  /"sys_cpu"[[:space:]]*:/ {
    if (!sys_set && match($0, /:[[:space:]]*([0-9]+\.?[0-9]*)/, v)) {
      sys=v[1]+0; sys_set=1
    }
  }

  END {
    total_iops = int(r_iops + w_iops)
    total_bw   = (r_bw + w_bw) / 1048576   # bytes -> MiB/s
    p50_ns  = (r_p50  > w_p50)  ? r_p50  : w_p50
    p99_ns  = (r_p99  > w_p99)  ? r_p99  : w_p99
    p999_ns = (r_p999 > w_p999) ? r_p999 : w_p999

    print total_iops
    print total_bw
    print r_mean  / 1000000   # ns -> ms  (read avg latency)
    print w_mean  / 1000000   # ns -> ms  (write avg latency)
    print r_std   / 1000000   # ns -> ms  (read latency stddev)
    print w_std   / 1000000   # ns -> ms  (write latency stddev)
    print p50_ns  / 1000000
    print p99_ns  / 1000000
    print p999_ns / 1000000
    print usr
    print sys
  }
  ' "$json_file"
}

# ---------------------------------------------------------------------------
# Core benchmark function
#
# Usage: run_fio <name> <rw> <bs> <numjobs> <size> <iodepth> [extra fio args...]
# Stores raw pipe-delimited values in RESULTS (formatted at report time).
# Progress goes to stderr so stdout stays clean for JSON/CSV piping.
# ---------------------------------------------------------------------------
run_fio() {
  local name="$1"
  local rw="$2"
  local bs="$3"
  local jobs="$4"
  local size="$5"
  local iodepth="$6"
  local extra_args=("${@:7}")

  local tmp_json="${WORK_DIR}/fio_${name}.json"
  local tmp_err="${WORK_DIR}/fio_${name}.err"

  printf "  Running %-22s (bs=%-5s jobs=%-2s iodepth=%-3s size=%-5s) ... " \
    "$name" "$bs" "$jobs" "$iodepth" "$size" >&2

  if "$DRY_RUN"; then
    printf "[DRY-RUN]\n" >&2
    printf "    fio --name=%s --filename=%s --rw=%s --bs=%s --numjobs=%s --iodepth=%s --size=%s --direct=1 --ioengine=libaio --time_based --runtime=%s --group_reporting --output-format=json" \
      "$name" "$TEST_TARGET" "$rw" "$bs" "$jobs" "$iodepth" "$size" "$RUNTIME" >&2
    printf " %s" "${extra_args[@]+"${extra_args[@]}"}" >&2
    printf "\n" >&2
    return
  fi

  local timeout_secs=$((RUNTIME * 3))
  if ! timeout "$timeout_secs" fio \
    --name="$name" \
    --filename="$TEST_TARGET" \
    --rw="$rw" \
    --bs="$bs" \
    --numjobs="$jobs" \
    --iodepth="$iodepth" \
    --size="$size" \
    --direct=1 \
    --ioengine=libaio \
    --time_based \
    --runtime="$RUNTIME" \
    --group_reporting \
    --output-format=json \
    "${extra_args[@]}" \
    > "$tmp_json" \
    2> "$tmp_err"; then
    printf "FAILED\n" >&2
    log_error "fio failed for test '${name}'. Stderr:"
    cat -- "$tmp_err" >&2
    exit 1
  fi

  local parsed_output
  if ! parsed_output=$(parse_fio_metrics "$tmp_json"); then
    log_error "Failed to parse fio output for test '${name}'"
    exit 1
  fi

  local -a metrics
  readarray -t metrics <<< "$parsed_output"

  local iops="${metrics[0]}"
  local bw="${metrics[1]}"
  local r_lat="${metrics[2]}"
  local w_lat="${metrics[3]}"
  local r_std="${metrics[4]}"
  local w_std="${metrics[5]}"
  local p50="${metrics[6]}"
  local p99="${metrics[7]}"
  local p999="${metrics[8]}"
  local cpu_u="${metrics[9]}"
  local cpu_s="${metrics[10]}"

  # IOPS per 1% of combined CPU — hypervisor overhead comparison
  local eff
  eff=$(awk "BEGIN {
    t = ${cpu_u} + ${cpu_s}
    if (t > 0) printf \"%d\", ${iops} / t
    else       printf \"N/A\"
  }")

  RESULTS+=("${name}|${iops}|${bw}|${r_lat}|${w_lat}|${r_std}|${w_std}|${p50}|${p99}|${p999}|${cpu_u}|${cpu_s}|${eff}")

  printf "Done.\n" >&2
}

# ---------------------------------------------------------------------------
# Report — text
# ---------------------------------------------------------------------------
_report_text() {
  printf "\nDetailed Storage Performance Report — fio v3+ | %s\n" \
    "$(date '+%Y-%m-%dT%H:%M:%S')"
  printf "%s\n" "$SEPARATOR"
  printf "  Device : %s\n" "$TEST_TARGET"
  printf "  Model  : %s  |  Type: %s  |  Capacity: %s GiB\n" \
    "$DEV_MODEL" "$DEV_TYPE" "$DEV_SIZE_GIB"
  printf "  Phys block: %s B  |  Scheduler: %s  |  Runtime per test: %ss\n" \
    "$DEV_PHY_BS" "$DEV_SCHEDULER" "$RUNTIME"
  printf "%s\n" "$SEPARATOR"
  printf "%-22s | %-8s | %-12s | %-10s | %-10s | %-10s | %-10s | %-10s | %-18s | %-10s\n" \
    "Test" "IOPS" "Bandwidth" "Rd Lat" "Wr Lat" "p50 Lat" "p99 Lat" "p99.9 Lat" \
    "CPU (usr / sys)" "IOPS/CPU"
  printf "%s\n" "$SEPARATOR"

  local row
  for row in "${RESULTS[@]}"; do
    local n iops bw r_lat w_lat r_std w_std p50 p99 p999 cu cs eff
    IFS='|' read -r n iops bw r_lat w_lat r_std w_std p50 p99 p999 cu cs eff <<< "$row"
    printf "%-22s | %-8s | %-12s | %-10s | %-10s | %-10s | %-10s | %-10s | %-18s | %-10s\n" \
      "$n" "$iops" \
      "$(printf "%.1f MiB/s" "$bw")" \
      "$(printf "%.2f ms" "$r_lat")" \
      "$(printf "%.2f ms" "$w_lat")" \
      "$(printf "%.2f ms" "$p50")" \
      "$(printf "%.2f ms" "$p99")" \
      "$(printf "%.2f ms" "$p999")" \
      "$(printf "%.2f%% / %.2f%%" "$cu" "$cs")" \
      "$eff"
  done

  printf "%s\n\n" "$SEPARATOR"
}

# ---------------------------------------------------------------------------
# Report — CSV  (main results + optional sweep sections)
# ---------------------------------------------------------------------------
_report_csv() {
  printf "test,iops,bandwidth_mib,r_lat_ms,w_lat_ms,r_std_ms,w_std_ms,lat_p50_ms,lat_p99_ms,lat_p999_ms,cpu_usr_pct,cpu_sys_pct,iops_per_cpu\n"
  local row
  for row in "${RESULTS[@]}"; do
    local n iops bw r_lat w_lat r_std w_std p50 p99 p999 cu cs eff
    IFS='|' read -r n iops bw r_lat w_lat r_std w_std p50 p99 p999 cu cs eff <<< "$row"
    printf "%s,%s,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%s\n" \
      "$n" "$iops" "$bw" "$r_lat" "$w_lat" "$r_std" "$w_std" "$p50" "$p99" "$p999" "$cu" "$cs" "$eff"
  done

  if [[ "${#SWEEP_RESULTS[@]}" -gt 0 ]]; then
    printf "\n# iodepth_sweep\n"
    printf "iodepth,iops,bandwidth_mib,lat_avg_ms,lat_p99_ms\n"
    local srow
    for srow in "${SWEEP_RESULTS[@]}"; do
      local d si sbw slat sp99
      IFS='|' read -r d si sbw slat sp99 <<< "$srow"
      printf "%s,%s,%.3f,%.4f,%.4f\n" "$d" "$si" "$sbw" "$slat" "$sp99"
    done
  fi

  if [[ "${#RWMIX_RESULTS[@]}" -gt 0 ]]; then
    printf "\n# rwmix_sweep\n"
    printf "write_pct,iops,bandwidth_mib,lat_avg_ms,lat_p99_ms\n"
    local mrow
    for mrow in "${RWMIX_RESULTS[@]}"; do
      local pct mi mbw mlat mp99
      IFS='|' read -r pct mi mbw mlat mp99 <<< "$mrow"
      printf "%s,%s,%.3f,%.4f,%.4f\n" "$pct" "$mi" "$mbw" "$mlat" "$mp99"
    done
  fi
}

# ---------------------------------------------------------------------------
# Report — JSON  (single document; sweeps embedded when present)
# ---------------------------------------------------------------------------
_report_json() {
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')

  printf '{\n'
  printf '  "timestamp": "%s",\n'   "$ts"
  printf '  "device": {\n'
  printf '    "path": "%s",\n'       "$TEST_TARGET"
  printf '    "model": "%s",\n'      "$DEV_MODEL"
  printf '    "type": "%s",\n'       "$DEV_TYPE"
  printf '    "capacity_gib": "%s",\n' "$DEV_SIZE_GIB"
  printf '    "phys_block_bytes": "%s",\n' "$DEV_PHY_BS"
  printf '    "scheduler": "%s"\n'   "$DEV_SCHEDULER"
  printf '  },\n'
  printf '  "runtime_secs": %s,\n'  "$RUNTIME"
  printf '  "results": [\n'

  local first=true row
  for row in "${RESULTS[@]}"; do
    local n iops bw r_lat w_lat r_std w_std p50 p99 p999 cu cs eff
    IFS='|' read -r n iops bw r_lat w_lat r_std w_std p50 p99 p999 cu cs eff <<< "$row"
    "$first" || printf ',\n'
    first=false
    printf '    {"test":"%s","iops":%s,"bandwidth_mib":%.3f,"r_lat_ms":%.4f,"w_lat_ms":%.4f,"r_std_ms":%.4f,"w_std_ms":%.4f,"lat_p50_ms":%.4f,"lat_p99_ms":%.4f,"lat_p999_ms":%.4f,"cpu_usr_pct":%.2f,"cpu_sys_pct":%.2f,"iops_per_cpu":"%s"}' \
      "$n" "$iops" "$bw" "$r_lat" "$w_lat" "$r_std" "$w_std" "$p50" "$p99" "$p999" "$cu" "$cs" "$eff"
  done
  printf '\n  ]'

  if [[ "${#SWEEP_RESULTS[@]}" -gt 0 ]]; then
    printf ',\n  "iodepth_sweep": [\n'
    first=true
    local srow
    for srow in "${SWEEP_RESULTS[@]}"; do
      local d si sbw slat sp99
      IFS='|' read -r d si sbw slat sp99 <<< "$srow"
      "$first" || printf ',\n'
      first=false
      printf '    {"iodepth":%s,"iops":%s,"bandwidth_mib":%.3f,"lat_avg_ms":%.4f,"lat_p99_ms":%.4f}' \
        "$d" "$si" "$sbw" "$slat" "$sp99"
    done
    printf '\n  ]'
  fi

  if [[ "${#RWMIX_RESULTS[@]}" -gt 0 ]]; then
    printf ',\n  "rwmix_sweep": [\n'
    first=true
    local mrow
    for mrow in "${RWMIX_RESULTS[@]}"; do
      local pct mi mbw mlat mp99
      IFS='|' read -r pct mi mbw mlat mp99 <<< "$mrow"
      "$first" || printf ',\n'
      first=false
      printf '    {"write_pct":%s,"iops":%s,"bandwidth_mib":%.3f,"lat_avg_ms":%.4f,"lat_p99_ms":%.4f}' \
        "$pct" "$mi" "$mbw" "$mlat" "$mp99"
    done
    printf '\n  ]'
  fi

  printf '\n}\n'
}

# ---------------------------------------------------------------------------
# iodepth sweep — randread, bs=4k, numjobs=1, iodepth in SWEEP_DEPTHS
# ---------------------------------------------------------------------------
run_iodepth_sweep() {
  printf "  iodepth sweep (randread, bs=4k, numjobs=1):\n" >&2

  local depth
  for depth in "${SWEEP_DEPTHS[@]}"; do
    local name="sweep_qd${depth}"
    local tmp_json="${WORK_DIR}/fio_${name}.json"
    local tmp_err="${WORK_DIR}/fio_${name}.err"

    printf "    iodepth=%-4s ... " "$depth" >&2

    if "$DRY_RUN"; then
      printf "[DRY-RUN]\n" >&2
      printf "      fio --name=%s --filename=%s --rw=randread --bs=4k --numjobs=1 --iodepth=%s --size=1G --direct=1 --ioengine=libaio --time_based --runtime=%s --group_reporting --output-format=json\n" \
        "$name" "$TEST_TARGET" "$depth" "$RUNTIME" >&2
      continue
    fi

    local timeout_secs=$((RUNTIME * 3))
    if ! timeout "$timeout_secs" fio \
      --name="$name" \
      --filename="$TEST_TARGET" \
      --rw=randread \
      --bs=4k \
      --numjobs=1 \
      --iodepth="$depth" \
      --size=1G \
      --direct=1 \
      --ioengine=libaio \
      --time_based \
      --runtime="$RUNTIME" \
      --group_reporting \
      --output-format=json \
      --randrepeat=0 \
      --norandommap \
      > "$tmp_json" \
      2> "$tmp_err"; then
      printf "FAILED\n" >&2
      log_error "fio sweep failed at iodepth=${depth}. Stderr:"
      cat -- "$tmp_err" >&2
      exit 1
    fi

    local parsed_output
    if ! parsed_output=$(parse_fio_metrics "$tmp_json"); then
      log_error "Failed to parse fio output for iodepth sweep at depth=${depth}"
      exit 1
    fi

    local -a metrics
    readarray -t metrics <<< "$parsed_output"

    # Store: depth | iops | bw | r_lat_avg | p99
    SWEEP_RESULTS+=("${depth}|${metrics[0]}|${metrics[1]}|${metrics[2]}|${metrics[7]}")

    printf "Done.\n" >&2
  done
}

print_sweep_report() {
  printf "\niodepth Sweep — randread, bs=4k, numjobs=1\n"
  printf "%s\n" "$SWEEP_SEPARATOR"
  printf "%-10s | %-8s | %-12s | %-10s | %-10s\n" \
    "iodepth" "IOPS" "Bandwidth" "Avg Lat" "p99 Lat"
  printf "%s\n" "$SWEEP_SEPARATOR"

  local row
  for row in "${SWEEP_RESULTS[@]}"; do
    local d i bw lat p99
    IFS='|' read -r d i bw lat p99 <<< "$row"
    printf "%-10s | %-8s | %-12s | %-10s | %-10s\n" \
      "$d" "$i" \
      "$(printf "%.1f MiB/s" "$bw")" \
      "$(printf "%.2f ms" "$lat")" \
      "$(printf "%.2f ms" "$p99")"
  done

  printf "%s\n\n" "$SWEEP_SEPARATOR"
}

# ---------------------------------------------------------------------------
# RW-mix sweep — randrw, bs=4k, numjobs=8, write% in RWMIX_WRITES
# ---------------------------------------------------------------------------
run_rwmix_sweep() {
  printf "  RW-mix sweep (randrw, bs=4k, numjobs=8):\n" >&2

  local pct
  for pct in "${RWMIX_WRITES[@]}"; do
    local name="rwmix_w${pct}"
    local tmp_json="${WORK_DIR}/fio_${name}.json"
    local tmp_err="${WORK_DIR}/fio_${name}.err"

    printf "    write=%-4s%% ... " "$pct" >&2

    if "$DRY_RUN"; then
      printf "[DRY-RUN]\n" >&2
      printf "      fio --name=%s --filename=%s --rw=randrw --bs=4k --numjobs=8 --rwmixwrite=%s --size=1G --direct=1 --ioengine=libaio --time_based --runtime=%s --group_reporting --output-format=json\n" \
        "$name" "$TEST_TARGET" "$pct" "$RUNTIME" >&2
      continue
    fi

    local timeout_secs=$((RUNTIME * 3))
    if ! timeout "$timeout_secs" fio \
      --name="$name" \
      --filename="$TEST_TARGET" \
      --rw=randrw \
      --bs=4k \
      --numjobs=8 \
      --iodepth=8 \
      --rwmixwrite="$pct" \
      --size=1G \
      --direct=1 \
      --ioengine=libaio \
      --time_based \
      --runtime="$RUNTIME" \
      --group_reporting \
      --output-format=json \
      --randrepeat=0 \
      --norandommap \
      > "$tmp_json" \
      2> "$tmp_err"; then
      printf "FAILED\n" >&2
      log_error "fio rwmix sweep failed at write=${pct}%%. Stderr:"
      cat -- "$tmp_err" >&2
      exit 1
    fi

    local parsed_output
    if ! parsed_output=$(parse_fio_metrics "$tmp_json"); then
      log_error "Failed to parse fio output for rwmix sweep at write=${pct}%%"
      exit 1
    fi

    local -a metrics
    readarray -t metrics <<< "$parsed_output"

    # Store: write_pct | iops | bw | r_lat_avg | p99
    RWMIX_RESULTS+=("${pct}|${metrics[0]}|${metrics[1]}|${metrics[2]}|${metrics[7]}")

    printf "Done.\n" >&2
  done
}

print_rwmix_report() {
  printf "\nRW-mix Sweep — randrw, bs=4k, numjobs=8\n"
  printf "%s\n" "$RWMIX_SEPARATOR"
  printf "%-12s | %-8s | %-12s | %-10s | %-10s\n" \
    "Write %" "IOPS" "Bandwidth" "Avg Lat" "p99 Lat"
  printf "%s\n" "$RWMIX_SEPARATOR"

  local row
  for row in "${RWMIX_RESULTS[@]}"; do
    local pct i bw lat p99
    IFS='|' read -r pct i bw lat p99 <<< "$row"
    printf "%-12s | %-8s | %-12s | %-10s | %-10s\n" \
      "${pct}%" "$i" \
      "$(printf "%.1f MiB/s" "$bw")" \
      "$(printf "%.2f ms" "$lat")" \
      "$(printf "%.2f ms" "$p99")"
  done

  printf "%s\n\n" "$RWMIX_SEPARATOR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if (($# > 0)); then
    parse_args "$@"
  else
    TEST_TARGET="$DEFAULT_TARGET"
    RUNTIME="$DEFAULT_RUNTIME"
    interactive_prompts
  fi

  check_deps
  validate_inputs
  collect_device_info

  WORK_DIR="$(mktemp -d)"
  declare -a RESULTS=()
  declare -a SWEEP_RESULTS=()
  declare -a RWMIX_RESULTS=()

  printf "\n=== FIO Benchmark v%s ===\n\n" "$SCRIPT_VERSION" >&2

  #            name              rw            bs      jobs  size    iodepth  [extra...]
  run_fio "seqread"        "read"        "8k"    8    "1G"   4
  run_fio "seqwrite"       "write"       "32k"   4    "2G"   4
  run_fio "seq128kread"    "read"        "128k"  8    "2G"   4
  run_fio "seq128kwrite"   "write"       "128k"  4    "2G"   4
  run_fio "randread"       "randread"    "8k"    16   "1G"   8    "--randrepeat=0" "--norandommap"
  run_fio "randwrite"      "randwrite"   "64k"   8    "512m" 8    "--randrepeat=0" "--norandommap"
  run_fio "rand4kread"     "randread"    "4k"    16   "1G"   8    "--randrepeat=0" "--norandommap"
  run_fio "rand4kwrite"    "randwrite"   "4k"    8    "1G"   8    "--randrepeat=0" "--norandommap"
  run_fio "randrw"         "randrw"      "16k"   8    "1G"   8    "--rwmixread=90" "--randrepeat=0" "--norandommap"

  if "$DO_SWEEP"; then
    printf "\n" >&2
    run_iodepth_sweep
  fi

  if "$DO_RWMIX"; then
    printf "\n" >&2
    run_rwmix_sweep
  fi

  "$DRY_RUN" && return

  case "$OUTPUT_FORMAT" in
    json)
      _report_json
      ;;
    csv)
      _report_csv
      ;;
    *)
      _report_text
      [[ "${#SWEEP_RESULTS[@]}" -gt 0 ]] && print_sweep_report
      [[ "${#RWMIX_RESULTS[@]}" -gt 0 ]] && print_rwmix_report
      ;;
  esac
}

main "$@"
