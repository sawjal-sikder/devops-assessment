#!/usr/bin/env bash
# Linux host snapshot. Requires Bash 4+, procfs, GNU coreutils, procps, and util-linux.
set -euo pipefail
set -E
export LC_ALL=C
umask 027
trap 'printf "[CRITICAL] Health collection/logging failed at line %s.\n" "$LINENO" >&2; exit 2' ERR

usage() {
  cat <<'HELP'
Usage: system_health.sh [OPTIONS]
Collect CPU, memory, every mounted filesystem, load averages, and top 5 RSS processes.
Disk alerts apply to writable capacity-bearing filesystems; all mounts are reported.
Append one timestamped snapshot to health_log.txt and print it to stdout.

  --json                   Emit/append one JSON object per run (JSON Lines).
  --cpu PERCENT            CPU warning threshold (default: 90).
  --mem PERCENT            Memory warning threshold (default: 85).
  --disk PERCENT           Per-filesystem warning threshold (default: 80).
  --critical-cpu PERCENT   CPU critical threshold (default: 95).
  --critical-mem PERCENT   Memory critical threshold (default: 95).
  --critical-disk PERCENT  Disk critical threshold (default: 95).
  --sample-seconds NUMBER  CPU sampling interval, > 0 and <= 60 (default: 1).
  --log-file PATH          Log location (default: ./health_log.txt).
  --max-log-bytes INTEGER  Rotate before an append exceeds this size (default: 1048576).
  --keep-logs INTEGER      Number of rotated archives, 1..100 (default: 5).
  --df-timeout INTEGER     Per-filesystem stat timeout, 1..60 seconds (default: 5).
  --proc-root PATH         Alternate procfs for diagnostics (default: /proc).
  --help                   Show this help.

Thresholds are integer percentages, 1..100; warning must not exceed critical.
Usage at or above a threshold raises an alert. Warnings are written to stderr;
critical threshold warnings also carry [CRITICAL]. JSON stdout remains parseable.
Exit codes: 0 healthy, 1 warning, 2 critical or invalid input/collection/logging failure.
Use a trusted log directory and one output format per log. Rotation retains
max-log-bytes per new active file, with keep-logs archives and one .lock file.
HELP
}

die() {
  printf '[CRITICAL] %s\n' "$*" >&2
  exit 2
}

json_quote() {
  local value=$1 result='"' char code i
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    case "$char" in
      '"') result+='\"' ;;
      \\) result+="\\\\" ;;
      *)
        printf -v code '%d' "'$char"
        if ((code < 32)); then
          printf -v char '\\u%04x' "$code"
        fi
        result+=$char
        ;;
    esac
  done
  printf '%s"' "$result"
}

# Functions below run in main's scope; these arrays/status are intentionally shared.
record_alert() {
  local severity=$1 message=$2 prefix='[WARNING]'
  if [[ "$severity" == critical ]]; then
    status=2
    prefix='[WARNING] [CRITICAL]'
  elif ((status < 1)); then
    status=1
  fi
  printf '%s %s\n' "$prefix" "$message" >&2
  alerts+=("{\"severity\":$(json_quote "$severity"),\"message\":$(json_quote "$message")}")
}

check_threshold() {
  local metric=$1 value=$2 warning=$3 critical=$4
  if awk -v value="$value" -v limit="$critical" 'BEGIN {exit !(value >= limit)}'; then
    record_alert critical "$metric usage ${value}% reached critical threshold ${critical}%."
  elif awk -v value="$value" -v limit="$warning" 'BEGIN {exit !(value >= limit)}'; then
    record_alert warning "$metric usage ${value}% reached warning threshold ${warning}%."
  fi
}

cpu_counters() {
  awk '$1 == "cpu" {
    if (NF < 9) exit 1
    total=0
    for (i=2; i<=9; i++) total += $i
    printf "%.0f %.0f\n", total, $5+$6
    found=1
    exit
  } END {if (!found) exit 1}' "$proc_root/stat"
}

main() {
  local json=false cpu_warning=90 mem_warning=85 disk_warning=80
  local cpu_critical=95 mem_critical=95 disk_critical=95 sample_seconds=1
  local log_file=./health_log.txt max_log_bytes=1048576 keep_logs=5 df_timeout=5
  local proc_root=/proc flag value threshold dependency
  while (($#)); do
    flag=$1
    case "$flag" in
      --help) usage; exit 0 ;;
      --json) json=true; shift; continue ;;
      --cpu|--mem|--disk|--critical-cpu|--critical-mem|--critical-disk|--sample-seconds|--log-file|--max-log-bytes|--keep-logs|--df-timeout|--proc-root)
        (($# >= 2)) || die "Missing value for $flag."
        value=$2
        [[ -n "$value" ]] || die "Empty value for $flag."
        case "$flag" in
          --cpu) cpu_warning=$value ;;
          --mem) mem_warning=$value ;;
          --disk) disk_warning=$value ;;
          --critical-cpu) cpu_critical=$value ;;
          --critical-mem) mem_critical=$value ;;
          --critical-disk) disk_critical=$value ;;
          --sample-seconds) sample_seconds=$value ;;
          --log-file) log_file=$value ;;
          --max-log-bytes) max_log_bytes=$value ;;
          --keep-logs) keep_logs=$value ;;
          --df-timeout) df_timeout=$value ;;
          --proc-root) proc_root=$value ;;
        esac
        shift 2
        ;;
      *) die "Unknown option: $flag. Use --help." ;;
    esac
  done
  for threshold in "$cpu_warning" "$mem_warning" "$disk_warning" "$cpu_critical" "$mem_critical" "$disk_critical"; do
    [[ "$threshold" =~ ^[0-9]{1,3}$ ]] || die 'Thresholds must be integers from 1 to 100.'
    ((10#$threshold >= 1 && 10#$threshold <= 100)) || die 'Thresholds must be integers from 1 to 100.'
  done
  cpu_warning=$((10#$cpu_warning)); mem_warning=$((10#$mem_warning)); disk_warning=$((10#$disk_warning))
  cpu_critical=$((10#$cpu_critical)); mem_critical=$((10#$mem_critical)); disk_critical=$((10#$disk_critical))
  ((cpu_warning <= cpu_critical && mem_warning <= mem_critical && disk_warning <= disk_critical)) || die 'Warning thresholds must not exceed critical thresholds.'
  if [[ ! "$max_log_bytes" =~ ^[1-9][0-9]{0,9}$ ]] || ((max_log_bytes > 1073741824)); then die 'max-log-bytes must be 1..1073741824.'; fi
  if [[ ! "$keep_logs" =~ ^[1-9][0-9]{0,2}$ ]] || ((keep_logs > 100)); then die 'keep-logs must be 1..100.'; fi
  if [[ ! "$df_timeout" =~ ^[1-9][0-9]?$ ]] || ((df_timeout > 60)); then die 'df-timeout must be 1..60.'; fi
  [[ "$sample_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'Invalid sample-seconds.'
  awk -v value="$sample_seconds" 'BEGIN {exit !(value > 0 && value <= 60)}' || die 'sample-seconds must be > 0 and <= 60.'
  sample_seconds=$(awk -v value="$sample_seconds" 'BEGIN {printf "%.9g", value}')
  for dependency in awk df ps timeout flock date hostname stat mkdir mv sleep; do
    command -v "$dependency" >/dev/null || die "Missing required command: $dependency."
  done
  [[ -d "$proc_root" ]] || die "Missing procfs directory: $proc_root."
  mkdir -p -- "$(dirname -- "$log_file")"
  [[ ! -L "$log_file" && ! -L "$log_file.lock" ]] || die 'Refusing symlink log/lock files.'
  [[ ! -e "$log_file" || -f "$log_file" ]] || die 'Log path must be a regular file.'
  exec 9>>"$log_file.lock"
  flock -w 10 9 || die 'Timed out acquiring the health log lock.'

  local status=0 cpu_before idle_before cpu_after idle_after cpu_total cpu_idle cpu_usage
  local mem_total_kib mem_available_kib mem_usage load1 load5 load15 timestamp host
  local -a alerts=() disks=() processes=()
  read -r cpu_before idle_before < <(cpu_counters)
  sleep "$sample_seconds"
  read -r cpu_after idle_after < <(cpu_counters)
  cpu_total=$((cpu_after - cpu_before)); cpu_idle=$((idle_after - idle_before))
  ((cpu_total > 0 && cpu_idle >= 0 && cpu_idle <= cpu_total)) || die 'CPU counters did not advance or were reset; retry the sample.'
  cpu_usage=$(awk -v total="$cpu_total" -v idle="$cpu_idle" 'BEGIN {printf "%.2f", 100*(total-idle)/total}')
  read -r mem_total_kib mem_available_kib < <(awk '
    /^MemTotal:/ {total=$2}
    /^MemAvailable:/ {available=$2; found=1}
    END {if (total <= 0 || !found || available < 0 || available > total) exit 1; printf "%.0f %.0f\n", total, available}
  ' "$proc_root/meminfo")
  mem_usage=$(awk -v total="$mem_total_kib" -v available="$mem_available_kib" 'BEGIN {printf "%.2f", 100*(total-available)/total}')
  read -r load1 load5 load15 _ < "$proc_root/loadavg"
  for value in "$load1" "$load5" "$load15"; do
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'Invalid procfs load average.'
  done
  check_threshold CPU "$cpu_usage" "$cpu_warning" "$cpu_critical"
  check_threshold Memory "$mem_usage" "$mem_warning" "$mem_critical"

  local source mountpoint fstype mount_options fields size used available percent disk_error read_only capacity_applicable
  # procfs escapes spaces/tabs/newlines/backslashes as octal; decode without eval.
  while read -r source mountpoint fstype mount_options _; do
    source=$(printf '%b' "$source")
    mountpoint=$(printf '%b' "$mountpoint")
    disk_error=null
    read_only=false
    capacity_applicable=true
    if [[ ",$mount_options," == *,ro,* ]]; then read_only=true; fi
    case "$fstype" in
      proc|sysfs|devpts|cgroup|cgroup2|securityfs|debugfs|tracefs|pstore|bpf|configfs|mqueue|hugetlbfs|fusectl|nsfs|autofs)
        capacity_applicable=false
        ;;
    esac
    if [[ "$capacity_applicable" == false ]]; then
      size=null; used=null; available=null; percent=null
    elif fields=$(timeout "$df_timeout" df --block-size=1 --output=size,used,avail,pcent -- "$mountpoint" 2>/dev/null | awk 'NR == 2 {print $1, $2, $3, $4}'); then
      read -r size used available percent <<< "$fields"
      if [[ "$size" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ && "$available" =~ ^-?[0-9]+$ && "$percent" =~ ^[0-9]+%$ ]]; then
        percent=${percent%%%}
        if [[ "$read_only" == false ]]; then
          check_threshold "Disk $mountpoint" "$percent" "$disk_warning" "$disk_critical"
        fi
      elif [[ "$size" == 0 && "$used" == 0 && "$percent" == '-' ]]; then
        # proc/sysfs and other zero-capacity virtual filesystems are still reported.
        percent=null
      else
        size=null; used=null; available=null; percent=null
        disk_error='"unsupported filesystem statistics"'
        record_alert critical "Could not interpret filesystem statistics for $mountpoint."
      fi
    else
      size=null; used=null; available=null; percent=null
      disk_error='"unavailable or timed out"'
      record_alert critical "Filesystem $mountpoint is unavailable or df exceeded ${df_timeout}s."
    fi
    disks+=("{\"source\":$(json_quote "$source"),\"mountpoint\":$(json_quote "$mountpoint"),\"fstype\":$(json_quote "$fstype"),\"read_only\":$read_only,\"capacity_applicable\":$capacity_applicable,\"size_bytes\":$size,\"used_bytes\":$used,\"available_bytes\":$available,\"usage_percent\":$percent,\"error\":$disk_error}")
  done < "$proc_root/self/mounts"
  ((${#disks[@]} > 0)) || record_alert critical 'No mounted filesystems were found.'

  local process_data pid rss memory_percent command
  if process_data=$(ps -eo pid=,rss=,pmem=,comm= --sort=-rss | awk 'NR <= 5'); then
    while read -r pid rss memory_percent command; do
      [[ -n "$pid" ]] || continue
      [[ "$pid" =~ ^[0-9]+$ && "$rss" =~ ^[0-9]+$ && "$memory_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'Invalid process statistics.'
      processes+=("{\"pid\":$pid,\"command\":$(json_quote "$command"),\"rss_kib\":$rss,\"memory_percent\":$memory_percent}")
    done <<< "$process_data"
    ((${#processes[@]} > 0)) || record_alert critical 'No process statistics were returned.'
  else
    record_alert critical 'Failed to collect process statistics.'
  fi

  local disks_json processes_json alerts_json state entry bytes current_size i archive
  disks_json=$(IFS=,; printf '[%s]' "${disks[*]}")
  processes_json=$(IFS=,; printf '[%s]' "${processes[*]}")
  alerts_json=$(IFS=,; printf '[%s]' "${alerts[*]}")
  timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  host=$(hostname)
  case "$status" in 0) state=healthy ;; 1) state=warning ;; 2) state=critical ;; esac
  if [[ "$json" == true ]]; then
    entry="{\"timestamp\":$(json_quote "$timestamp"),\"hostname\":$(json_quote "$host"),\"status\":\"$state\",\"exit_code\":$status,\"cpu\":{\"usage_percent\":$cpu_usage,\"sample_seconds\":$sample_seconds},\"memory\":{\"total_bytes\":$((mem_total_kib*1024)),\"available_bytes\":$((mem_available_kib*1024)),\"usage_percent\":$mem_usage},\"load_average\":{\"1m\":$load1,\"5m\":$load5,\"15m\":$load15},\"filesystems\":$disks_json,\"top_processes\":$processes_json,\"alerts\":$alerts_json,\"thresholds\":{\"cpu\":$cpu_warning,\"mem\":$mem_warning,\"disk\":$disk_warning,\"critical_cpu\":$cpu_critical,\"critical_mem\":$mem_critical,\"critical_disk\":$disk_critical}}"
  else
    entry="$timestamp host=$host status=$state exit_code=$status CPU=${cpu_usage}% memory=${mem_usage}% load=$load1,$load5,$load15 filesystems=$disks_json top_processes=$processes_json alerts=$alerts_json"
  fi
  bytes=$((${#entry}+1))
  ((bytes <= max_log_bytes)) || die 'One snapshot exceeds max-log-bytes; increase the configured log size.'
  current_size=0
  if [[ -e "$log_file" ]]; then current_size=$(stat -c %s -- "$log_file"); fi
  if ((current_size + bytes > max_log_bytes)); then
    for ((i=1; i<=keep_logs; i++)); do
      archive="$log_file.$i"
      [[ ! -L "$archive" && (! -e "$archive" || -f "$archive") ]] || die "Refusing nonregular archive: $archive."
    done
    for ((i=keep_logs; i>=2; i--)); do
      if [[ -e "$log_file.$((i-1))" ]]; then mv -fT -- "$log_file.$((i-1))" "$log_file.$i"; fi
    done
    if [[ -e "$log_file" ]]; then mv -fT -- "$log_file" "$log_file.1"; fi
  fi
  printf '%s\n' "$entry" >> "$log_file"
  printf '%s\n' "$entry"
  exit "$status"
}

main "$@"
