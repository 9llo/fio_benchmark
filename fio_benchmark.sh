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
readonly SCRIPT_VERSION="1.3.0"

readonly DEFAULT_TARGET="/dev/sdb"
readonly DEFAULT_RUNTIME=600
SEPARATOR=$(printf '%0.s-' {1..117})
readonly SEPARATOR

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
trap 'printf "\n"; log_error "Interrupted."; exit 130' SIGINT SIGTERM

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info() { printf "[INFO]  %s\n" "$*" >&2; }
log_warn() { printf "[WARN]  %s\n" "$*" >&2; }
log_error() { printf "[ERROR] %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat << EOF
Usage: sudo ${SCRIPT_NAME} [OPTIONS]

Storage performance benchmark using fio. Runs 5 pre-defined tests:
  1. Sequential Read   – bs=8k,  numjobs=8,  size=1G
  2. Sequential Write  – bs=32k, numjobs=4,  size=2G
  3. Random Read       – bs=8k,  numjobs=16, size=1G
  4. Random Write      – bs=64k, numjobs=8,  size=512m
  5. Random Read/Write – bs=16k, numjobs=8,  size=1G, 90% reads

Options:
  -t DEVICE   Target block device or file  (default: ${DEFAULT_TARGET})
  -r RUNTIME  Test runtime in seconds      (default: ${DEFAULT_RUNTIME})
  -n          Dry-run: print fio commands without executing
  -v          Show version and exit
  -h          Show this help message

Requires: fio, bash (>= 4.4), awk

Examples:
  sudo ${SCRIPT_NAME} -t /dev/nvme0n1
  sudo ${SCRIPT_NAME} -t /dev/sdb -r 60
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

  local opt
  while getopts ":t:r:nvh" opt; do
    case "$opt" in
      t) TEST_TARGET="$OPTARG" ;;
      r) RUNTIME="$OPTARG" ;;
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
}

# ---------------------------------------------------------------------------
# Parse fio JSON output — single awk pass, no jq required
#
# Outputs 7 lines: IOPS | BW(MiB/s) | Lat(ms) | StdDev(ms) | p99(ms) | usr% | sys%
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
    r_p99=0;   w_p99=0;   r_p99_set=0;  w_p99_set=0
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

  /"99\.000000"[[:space:]]*:/ && in_perc {
    if (match($0, /:[[:space:]]*([0-9]+)/, v)) {
      if (section=="read"  && !r_p99_set) { r_p99=v[1]+0; r_p99_set=1 }
      if (section=="write" && !w_p99_set) { w_p99=v[1]+0; w_p99_set=1 }
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
    total_bw   = (r_bw   + w_bw)   / 1048576   # bytes  -> MiB/s
    total_lat  = (r_mean  + w_mean) / 1000000   # ns     -> ms
    total_std  = (r_std   + w_std)  / 1000000   # ns     -> ms
    p99_ns     = (r_p99 > w_p99) ? r_p99 : w_p99
    p99_ms     = p99_ns / 1000000               # ns     -> ms

    print total_iops
    print total_bw
    print total_lat
    print total_std
    print p99_ms
    print usr
    print sys
  }
  ' "$json_file"
}

# ---------------------------------------------------------------------------
# Core benchmark function
#
# Usage: run_fio <name> <rw> <bs> <numjobs> <size> [extra fio args...]
# ---------------------------------------------------------------------------
run_fio() {
  local name="$1"
  local rw="$2"
  local bs="$3"
  local jobs="$4"
  local size="$5"
  local extra_args=("${@:6}")

  local tmp_json="${WORK_DIR}/fio_${name}.json"
  local tmp_err="${WORK_DIR}/fio_${name}.err"

  printf "  Running %-20s (bs=%-4s jobs=%-2s size=%-5s) ... " "$name" "$bs" "$jobs" "$size"

  if "$DRY_RUN"; then
    printf "[DRY-RUN]\n"
    printf "    fio --name=%s --filename=%s --rw=%s --bs=%s --numjobs=%s --size=%s --direct=1 --ioengine=libaio --time_based --runtime=%s --group_reporting --output-format=json" \
      "$name" "$TEST_TARGET" "$rw" "$bs" "$jobs" "$size" "$RUNTIME"
    printf " %s" "${extra_args[@]+"${extra_args[@]}"}"
    printf "\n"
    return
  fi

  local timeout_secs=$((RUNTIME * 3))
  if ! timeout "$timeout_secs" fio \
    --name="$name" \
    --filename="$TEST_TARGET" \
    --rw="$rw" \
    --bs="$bs" \
    --numjobs="$jobs" \
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
    printf "FAILED\n"
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

  local iops_val="${metrics[0]}"
  local bw_mib="${metrics[1]}"
  local lat_ms="${metrics[2]}"
  local std_ms="${metrics[3]}"
  local p99_ms="${metrics[4]}"
  local cpu_u="${metrics[5]}"
  local cpu_s="${metrics[6]}"

  local bw_fmt lat_fmt std_fmt p99_fmt cpu_u_fmt cpu_s_fmt
  bw_fmt=$(printf "%.1f MiB/s" "$bw_mib")
  lat_fmt=$(printf "%.2f ms" "$lat_ms")
  std_fmt=$(printf "%.2f ms" "$std_ms")
  p99_fmt=$(printf "%.2f ms" "$p99_ms")
  cpu_u_fmt=$(printf "%.2f%%" "$cpu_u")
  cpu_s_fmt=$(printf "%.2f%%" "$cpu_s")

  RESULTS+=("${name}|${iops_val}|${bw_fmt}|${lat_fmt}|${std_fmt}|${p99_fmt}|${cpu_u_fmt} / ${cpu_s_fmt}")

  printf "Done.\n"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
print_report() {
  printf "\nDetailed Storage Performance Report — fio v3+ | %s\n" "$(date '+%Y-%m-%dT%H:%M:%S')"
  printf "%s\n" "$SEPARATOR"
  printf "  Device: %s  |  Runtime per test: %ss\n" "$TEST_TARGET" "$RUNTIME"
  printf "%s\n" "$SEPARATOR"
  printf "%-20s | %-8s | %-12s | %-10s | %-10s | %-10s | %-18s\n" \
    "Test" "IOPS" "Bandwidth" "Avg Lat" "StdDev" "p99 Lat" "CPU (usr / sys)"
  printf "%s\n" "$SEPARATOR"

  local row
  for row in "${RESULTS[@]}"; do
    local n i b a std p u
    IFS='|' read -r n i b a std p u <<< "$row"
    printf "%-20s | %-8s | %-12s | %-10s | %-10s | %-10s | %-18s\n" \
      "$n" "$i" "$b" "$a" "$std" "$p" "$u"
  done

  printf "%s\n\n" "$SEPARATOR"
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

  WORK_DIR="$(mktemp -d)"
  declare -a RESULTS=()

  printf "\n=== FIO Benchmark v%s ===\n\n" "$SCRIPT_VERSION"

  #            name           rw         bs     jobs  size    [extra...]
  run_fio "seqread" "read" "8k" 8 "1G"
  run_fio "seqwrite" "write" "32k" 4 "2G"
  run_fio "randread" "randread" "8k" 16 "1G"
  run_fio "randwrite" "randwrite" "64k" 8 "512m"
  run_fio "randrw" "randrw" "16k" 8 "1G" "--rwmixread=90"

  "$DRY_RUN" || print_report
}

main "$@"
