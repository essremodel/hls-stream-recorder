#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# HLS Stream Recorder — MAX QUALITY
# 1) Parses master m3u8 to find highest bitrate variant
# 2) Runs a 15s test to verify stream + quality
# 3) Records 5-min segments across scheduled windows
#    or in a custom on-demand time range
# All files saved next to this script
# ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTTP_USER_AGENT="${HLS_RECORDER_USER_AGENT:-Mozilla/5.0 (HLS Stream Recorder)}"
ACTIVE_HTTP_USER_AGENT="$HTTP_USER_AGENT"
CHANNELS_CONF_FILE="${SCRIPT_DIR}/channels.conf"
STREAMS_FILE="${SCRIPT_DIR}/streams.txt"
CHANNELS_HELPER_FILE="${SCRIPT_DIR}/channels.sh"
MASTER_URL=""
OUT_DIR=""
OUTPUT_OVERRIDE=""
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/recording_$(date +%Y%m%d)"
DEFAULT_MONITOR_OUTPUT_DIR="${SCRIPT_DIR}/recording_monitor_$(date +%Y%m%d)"
QUIET=0
STREAM_SELECTOR=""
STREAM_TEST_FLAG=0
UPDATE_CHANNELS_FLAG=0
MODE_OVERRIDE=""
SELECTED_NAME=""
SELECTED_SHORT=""
SELECTED_CATEGORY=""
SELECTED_NOTES=""
SELECTED_SOURCE=""
SELECTED_PROBE_SUMMARY=""
SELECTED_STREAM_USER_AGENT=""
SELECTED_CATALOG_INDEX=""
STREAM_SELECTION_VALIDATED=0
STREAM_PROBE_TIMEOUT_SEC=5
STREAM_TEST_TIMEOUT_SEC=8
STREAM_TEST_TOTAL_TIMEOUT_SEC=20
STREAM_TEST_MAX_PARALLEL=5
BASE_DEPS_READY=0
CATALOG_LOADED=0

SEGMENT_SEC=300  # 5 minutes
TEST_SEC=15
MAX_DURATION_MIN=1440
SEGMENT_TIMEOUT_MULTIPLIER=2
SLOW_SEGMENT_GRACE_SEC=15
MONITOR_SEGMENT_SEC=150
MONITOR_BUFFER_MINUTES=5
MONITOR_BUFFER_SEC=$((MONITOR_BUFFER_MINUTES * 60))
MONITOR_FLAG=0
MONITOR_KEYWORDS_FILE="${SCRIPT_DIR}/keywords.txt"
MONITOR_UNTIL_RAW=""
MONITOR_UNTIL_SEC=""
MONITOR_CC_METHOD="${HLS_MONITOR_CC_METHOD:-auto}"
MONITOR_ACTIVE=0
MONITOR_INTERRUPTED=0
MONITOR_SUMMARY_PRINTED=0
MONITOR_STATUS_LINES=0
MONITOR_MATCHES_FOUND=0
MONITOR_BUFFER_DIR=""
MONITOR_KEPT_DIR=""
MONITOR_LOG_FILE=""
MONITOR_LAST_CC_PREVIEW=""
MONITOR_LAST_MATCH_SUMMARY=""
MONITOR_EMPTY_CC_STREAK=0
MONITOR_LAST_SEGMENT_RECORDED=0
MONITOR_BEST_URL=""
MONITOR_STREAM_SUMMARY=""
MONITOR_HAS_CC_DECLARED=0
MONITOR_HAS_SUBTITLE_DECLARED=0

[ -f "$CHANNELS_HELPER_FILE" ] || {
    echo "Missing channel helper: $CHANNELS_HELPER_FILE" >&2
    exit 1
}
# shellcheck source=./channels.sh
. "$CHANNELS_HELPER_FILE"

declare -a TEMP_FILES=()
declare -a ACTIVE_PIDS=()
CLEANUP_DONE=0
declare -A STREAM_HEALTH_STATUS=()
declare -A STREAM_HEALTH_RESOLUTION=()
declare -A STREAM_HEALTH_BITRATE=()
declare -A STREAM_HEALTH_ERROR=()
declare -A STREAM_HEALTH_PROBE_SUMMARY=()
declare -A MONITOR_FLAGGED_SEGMENTS=()
declare -A MONITOR_SEG_MP4=()
declare -A MONITOR_SEG_SRT=()
declare -A MONITOR_SEG_TXT=()
declare -A MONITOR_MATCH_START=()
declare -A MONITOR_MATCH_END=()
declare -A MONITOR_MATCH_KEYWORDS=()
declare -A MONITOR_MATCH_FIRST_TS=()
declare -A MONITOR_MATCH_HITS=()
declare -A MONITOR_MATCH_DIR=()
declare -A MONITOR_MATCH_FINALIZED=()
NEXT_MONITOR_MATCH_ID=1

# ── Scheduled recording windows (24h format) ──
# Window 1: 5:55 PM → 7:00 PM  (5 min early cushion)
# Window 2: 9:55 PM → 11:00 PM (5 min early cushion)
WIN1_START_HOUR=17; WIN1_START_MIN=55
WIN1_END_HOUR=19;   WIN1_END_MIN=0

WIN2_START_HOUR=21; WIN2_START_MIN=55
WIN2_END_HOUR=23;   WIN2_END_MIN=0

# Colors
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'
B='\033[1m'; D='\033[2m'; NC='\033[0m'; W='\033[97m'
BG_C='\033[46;30m'; BG_G='\033[42;30m'; BG_R='\033[41;37m'; BG_Y='\033[43;30m'

SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

draw_bar() {
    local pct="$1" w="${2:-30}"
    local f=$((pct * w / 100)) e=$((w - f))
    local i
    for (( i=0; i<f; i++ )); do printf '█'; done
    for (( i=0; i<e; i++ )); do printf '░'; done
}

human_size() {
    echo "$1" | python3 -c "
b=int(open('/dev/stdin').read())
for u in ['B','KB','MB','GB']:
    if b<1024: print(f'{b:.1f} {u}'); break
    b/=1024
"
}

timestamp_now() {
    date '+%Y-%m-%d %H:%M:%S'
}

file_size_bytes() {
    [ -f "$1" ] || return 1
    wc -c < "$1" | tr -d ' '
}

count_nonempty_lines() {
    [ -f "$1" ] || {
        printf '0\n'
        return 0
    }
    grep -c '[^[:space:]]' "$1" 2>/dev/null || printf '0\n'
}

sum_dir_bytes() {
    local dir="$1"
    local total=0
    local file
    [ -d "$dir" ] || {
        printf '0\n'
        return 0
    }
    while IFS= read -r -d '' file; do
        size=$(file_size_bytes "$file" 2>/dev/null || printf '0')
        total=$((total + size))
    done < <(find "$dir" -type f -print0 2>/dev/null)
    printf '%s\n' "$total"
}

disk_free_kb() {
    df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

now_seconds_of_day() {
    local hour minute second
    hour=$(date +%H)
    minute=$(date +%M)
    second=$(date +%S)
    printf '%s\n' "$((10#$hour * 3600 + 10#$minute * 60 + 10#$second))"
}

make_temp_file() {
    mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}

open_output_dir() {
    local out_dir="$1"
    local os_name

    os_name=$(uname -s 2>/dev/null || echo "")
    case "$os_name" in
        Darwin)
            if command -v open &>/dev/null; then
                open "$out_dir"
                echo -e "  ${G}📂 Opened in Finder${NC}"
            fi
            ;;
        Linux)
            if command -v xdg-open &>/dev/null && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
                xdg-open "$out_dir" >/dev/null 2>&1 &
                echo -e "  ${G}📂 Opened output folder${NC}"
            else
                echo -e "  ${D}Output folder not opened automatically in this environment${NC}"
            fi
            ;;
    esac
}

set_default_windows() {
    WIN_STARTS=()
    WIN_ENDS=()
    WIN_LABELS=()

    WIN_STARTS+=("$((WIN1_START_HOUR*3600 + WIN1_START_MIN*60))")
    WIN_ENDS+=("$((WIN1_END_HOUR*3600 + WIN1_END_MIN*60))")
    WIN_LABELS+=("$(printf '%02d:%02d → %02d:%02d' "$WIN1_START_HOUR" "$WIN1_START_MIN" "$WIN1_END_HOUR" "$WIN1_END_MIN")")

    WIN_STARTS+=("$((WIN2_START_HOUR*3600 + WIN2_START_MIN*60))")
    WIN_ENDS+=("$((WIN2_END_HOUR*3600 + WIN2_END_MIN*60))")
    WIN_LABELS+=("$(printf '%02d:%02d → %02d:%02d' "$WIN2_START_HOUR" "$WIN2_START_MIN" "$WIN2_END_HOUR" "$WIN2_END_MIN")")
}

start_timeout_watchdog() {
    local target_pid="$1"
    local timeout_sec="$2"
    local marker_file="$3"

    (
        sleep "$timeout_sec"
        if kill -0 "$target_pid" 2>/dev/null; then
            printf 'timeout\n' > "$marker_file"
            kill "$target_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$target_pid" 2>/dev/null || true
        fi
    ) &
    printf '%s\n' "$!"
}

stop_timeout_watchdog() {
    local watchdog_pid="$1"
    [ -n "$watchdog_pid" ] || return 0
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    forget_pid "$watchdog_pid"
}

track_temp_file() {
    TEMP_FILES+=("$1")
}

forget_temp_file() {
    local target="$1"
    local kept=()
    local path
    for path in "${TEMP_FILES[@]}"; do
        [ "$path" != "$target" ] && kept+=("$path")
    done
    TEMP_FILES=("${kept[@]}")
}

track_pid() {
    ACTIVE_PIDS+=("$1")
}

forget_pid() {
    local target="$1"
    local kept=()
    local pid
    for pid in "${ACTIVE_PIDS[@]}"; do
        [ "$pid" != "$target" ] && kept+=("$pid")
    done
    ACTIVE_PIDS=("${kept[@]}")
}

cleanup() {
    local exit_code="${1:-$?}"
    local pid
    local path

    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return "$exit_code"
    fi
    CLEANUP_DONE=1

    for pid in "${ACTIVE_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done

    for pid in "${ACTIVE_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    monitor_cleanup_on_exit "$exit_code" || true

    for path in "${TEMP_FILES[@]}"; do
        rm -rf "$path"
    done

    return "$exit_code"
}

trap 'cleanup $?' EXIT
trap 'MONITOR_INTERRUPTED=1; cleanup 130; exit 130' INT
trap 'MONITOR_INTERRUPTED=1; cleanup 143; exit 143' TERM

parse_time() {
    local raw="$1"
    local cleaned hour minute meridiem

    cleaned=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    [ -z "$cleaned" ] && return 1

    if [[ ! "$cleaned" =~ ^([0-9]{1,2})(:([0-9]{1,2}))?([ap]m)?$ ]]; then
        return 1
    fi

    hour=$((10#${BASH_REMATCH[1]}))
    minute=$((10#${BASH_REMATCH[3]:-0}))
    meridiem="${BASH_REMATCH[4]:-}"

    if [ "$minute" -gt 59 ]; then
        return 1
    fi

    if [ -n "$meridiem" ]; then
        if [ "$hour" -lt 1 ] || [ "$hour" -gt 12 ]; then
            return 1
        fi
        if [ "$meridiem" = "am" ] && [ "$hour" -eq 12 ]; then
            hour=0
        elif [ "$meridiem" = "pm" ] && [ "$hour" -lt 12 ]; then
            hour=$((hour + 12))
        fi
    elif [ "$hour" -gt 23 ]; then
        return 1
    fi

    printf '%s\n' "$((hour * 3600 + minute * 60))"
}

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [url]

Record an HLS stream at the highest available quality.

Options:
  -h, --help          Show this help text and exit
  -q, --quiet         Suppress progress animations
      --stream REF    Select a built-in/custom stream by number or short name
      --test-streams  Probe all configured streams and report which are live
      --update-channels
                      Stub for future guide sync; prints a placeholder and exits
      --mode MODE     Choose recording mode (1-4, scheduled, duration, range, monitor)
      --monitor       Enable keyword monitor mode (experimental)
      --keywords FILE Use FILE for monitor keywords (default: keywords.txt)
      --until TIME    Stop monitor mode at TIME (e.g. 23:00)
      --segment-length SEC
                      Use SEC-second segments for monitor mode (default: 150)
      --url URL       Use URL as the HLS master playlist
      --output DIR    Write recordings to DIR

Arguments:
  url                 HLS master playlist URL (same as --url)

Examples:
  $(basename "$0") --stream cbs4
  $(basename "$0") --stream 1 --mode 2
  $(basename "$0") --stream abc --monitor
  $(basename "$0") --test-streams
  $(basename "$0") https://your-stream.com/index.m3u8
  $(basename "$0") --url https://your-stream.com/index.m3u8 --output /tmp/capture
  echo 1 | $(basename "$0") --quiet https://your-stream.com/index.m3u8
  $(basename "$0") --monitor --keywords ./keywords.txt --until 23:00
EOF
}

print_banner() {
    if [ "$QUIET" -eq 0 ] && [ -t 1 ]; then
        clear
    fi
    echo -e "${C}${B}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${C}${B}║          📡  HLS Stream Recorder  —  MAX QUALITY         ║${NC}"
    echo -e "${C}${B}╚═══════════════════════════════════════════════════════════╝${NC}"
}

ensure_catalog_loaded() {
    if [ "$CATALOG_LOADED" -eq 1 ]; then
        return 0
    fi
    channels_load_catalog "$CHANNELS_CONF_FILE" "$STREAMS_FILE" || return 1
    CATALOG_LOADED=1
}

ensure_selection_dependencies() {
    [ "$BASE_DEPS_READY" -eq 1 ] && return 0
    command -v ffprobe &>/dev/null || {
        echo -e "${R}✗ ffprobe not found! → brew install ffmpeg${NC}"
        exit 1
    }
    command -v python3 &>/dev/null || {
        echo -e "${R}✗ python3 not found!${NC}"
        exit 1
    }
    BASE_DEPS_READY=1
}

normalize_mode_selector() {
    local raw
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        1|scheduled)
            printf '1\n'
            ;;
        2|duration|now)
            printf '2\n'
            ;;
        3|range|time|time-range)
            printf '3\n'
            ;;
        4|monitor)
            printf '4\n'
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_stream_index() {
    local selector="$1"
    local short_key

    [ -n "$selector" ] || return 1
    short_key="$(channels_short_key "$selector")"

    if [[ "$short_key" =~ ^[0-9]+$ ]]; then
        local numeric=$((10#$short_key))
        if [ "$numeric" -ge 1 ] && [ "$numeric" -le "${#CHANNEL_SHORTS[@]}" ]; then
            printf '%s\n' "$((numeric - 1))"
            return 0
        fi
        return 1
    fi

    if [ -n "${CHANNEL_INDEX_BY_SHORT[$short_key]:-}" ]; then
        printf '%s\n' "${CHANNEL_INDEX_BY_SHORT[$short_key]}"
        return 0
    fi

    return 1
}

set_selected_stream_from_index() {
    local idx="$1"
    local notes_raw="${CHANNEL_NOTES[$idx]}"
    local notes_display=""
    local notes_ua=""

    MASTER_URL="${CHANNEL_URLS[$idx]}"
    SELECTED_NAME="${CHANNEL_NAMES[$idx]}"
    SELECTED_SHORT="${CHANNEL_SHORTS[$idx]}"
    SELECTED_CATEGORY="${CHANNEL_CATEGORIES[$idx]}"
    SELECTED_SOURCE="${CHANNEL_SOURCES[$idx]}"
    SELECTED_CATALOG_INDEX="$idx"
    SELECTED_PROBE_SUMMARY="${STREAM_HEALTH_PROBE_SUMMARY[$idx]:-}"
    STREAM_SELECTION_VALIDATED=0

    if notes_display=$(channels_notes_display "$notes_raw" 2>/dev/null); then
        SELECTED_NOTES="$notes_display"
    else
        SELECTED_NOTES=""
    fi

    if notes_ua=$(channels_user_agent_from_notes "$notes_raw" 2>/dev/null); then
        SELECTED_STREAM_USER_AGENT="$notes_ua"
    else
        SELECTED_STREAM_USER_AGENT=""
    fi
    ACTIVE_HTTP_USER_AGENT="${SELECTED_STREAM_USER_AGENT:-$HTTP_USER_AGENT}"
}

set_selected_manual_stream() {
    local raw_url="$1"
    local label="${2:-Manual URL}"
    local source="${3:-manual}"

    MASTER_URL="$raw_url"
    SELECTED_NAME="$label"
    SELECTED_SHORT="manual"
    SELECTED_CATEGORY="Manual"
    SELECTED_NOTES=""
    SELECTED_SOURCE="$source"
    SELECTED_PROBE_SUMMARY=""
    SELECTED_STREAM_USER_AGENT=""
    SELECTED_CATALOG_INDEX=""
    ACTIVE_HTTP_USER_AGENT="$HTTP_USER_AGENT"
    STREAM_SELECTION_VALIDATED=0
}

probe_stream_fields() {
    local url="$1"
    local user_agent="$2"
    local timeout_sec="$3"

    python3 - <<'PY' "$url" "$user_agent" "$timeout_sec"
import json
import subprocess
import sys

url, user_agent, timeout_raw = sys.argv[1:4]
timeout = float(timeout_raw)

def sanitize(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()

def bitrate_label(value):
    if not value:
        return ""
    try:
        numeric = int(float(value))
    except Exception:
        return ""
    if numeric >= 1_000_000:
        return f"{numeric / 1_000_000:.1f} Mbps"
    if numeric >= 1_000:
        return f"{numeric / 1_000:.0f} kbps"
    return f"{numeric} bps"

def resolution_label(video):
    width = video.get("width") or 0
    height = video.get("height") or 0
    try:
        width = int(width)
        height = int(height)
    except Exception:
        width = 0
        height = 0
    if height:
        return f"{height}p"
    if width and height:
        return f"{width}x{height}"
    return ""

cmd = ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams"]
if user_agent:
    cmd.extend(["-user_agent", user_agent])
cmd.extend(["-i", url])

try:
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
except subprocess.TimeoutExpired:
    sys.stdout.write("offline\t\t\ttimeout\t")
    sys.exit(124)
except FileNotFoundError:
    sys.stdout.write("offline\t\t\tffprobe not found\t")
    sys.exit(127)

if proc.returncode != 0 or not proc.stdout.strip():
    error = proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else "probe failed"
    sys.stdout.write(f"offline\t\t\t{sanitize(error)}\t")
    sys.exit(proc.returncode or 1)

try:
    payload = json.loads(proc.stdout)
except Exception as exc:
    sys.stdout.write(f"offline\t\t\t{sanitize(f'parse error: {exc}')}\t")
    sys.exit(1)

streams = payload.get("streams") or []
fmt = payload.get("format") or {}
video = next((stream for stream in streams if stream.get("codec_type") == "video"), {})
resolution = resolution_label(video)
bitrate = bitrate_label(fmt.get("bit_rate") or video.get("bit_rate") or "")
summary_parts = [part for part in (resolution, bitrate) if part]
summary = "  ".join(summary_parts) if summary_parts else "live"
sys.stdout.write(f"online\t{sanitize(resolution)}\t{sanitize(bitrate)}\t\t{sanitize(summary)}")
PY
}

cache_stream_health_result() {
    local key="$1"
    local result_line="$2"
    local status resolution bitrate error summary

    IFS=$'\t' read -r status resolution bitrate error summary <<< "$result_line"
    status="${status:-offline}"
    STREAM_HEALTH_STATUS["$key"]="$status"
    STREAM_HEALTH_RESOLUTION["$key"]="$resolution"
    STREAM_HEALTH_BITRATE["$key"]="$bitrate"
    STREAM_HEALTH_ERROR["$key"]="$error"
    STREAM_HEALTH_PROBE_SUMMARY["$key"]="$summary"
}

probe_selected_stream_once() {
    local force_refresh="${1:-0}"
    local cache_key=""
    local result_line
    local status=""
    local resolution=""
    local bitrate=""
    local error=""
    local summary=""

    if [ -n "$SELECTED_CATALOG_INDEX" ]; then
        cache_key="$SELECTED_CATALOG_INDEX"
    fi

    if [ -n "$cache_key" ] && [ "$force_refresh" -eq 0 ] && [ -n "${STREAM_HEALTH_STATUS[$cache_key]:-}" ]; then
        status="${STREAM_HEALTH_STATUS[$cache_key]}"
        resolution="${STREAM_HEALTH_RESOLUTION[$cache_key]:-}"
        bitrate="${STREAM_HEALTH_BITRATE[$cache_key]:-}"
        error="${STREAM_HEALTH_ERROR[$cache_key]:-}"
        summary="${STREAM_HEALTH_PROBE_SUMMARY[$cache_key]:-}"
    else
        result_line=$(probe_stream_fields "$MASTER_URL" "$ACTIVE_HTTP_USER_AGENT" "$STREAM_PROBE_TIMEOUT_SEC")
        IFS=$'\t' read -r status resolution bitrate error summary <<< "$result_line"
        status="${status:-offline}"
        if [ -n "$cache_key" ]; then
            cache_stream_health_result "$cache_key" "$result_line"
        fi
    fi

    if [ "$status" = "online" ]; then
        SELECTED_PROBE_SUMMARY="$summary"
        [ -n "$SELECTED_PROBE_SUMMARY" ] || SELECTED_PROBE_SUMMARY="live"
        return 0
    fi

    SELECTED_PROBE_SUMMARY=""
    if [ -n "$error" ]; then
        STREAM_HEALTH_ERROR["selected"]="$error"
    else
        STREAM_HEALTH_ERROR["selected"]="offline"
    fi
    return 1
}

suggest_alternate_stream_index() {
    local current_idx="$1"
    local current_short="${CHANNEL_SHORTS[$current_idx]}"
    local current_category="${CHANNEL_CATEGORIES[$current_idx]}"
    local sibling_short=""
    local idx

    if [[ "$current_short" == *-alt ]]; then
        sibling_short="${current_short%-alt}"
    else
        sibling_short="${current_short}-alt"
    fi

    if [ -n "$sibling_short" ] && [ -n "${CHANNEL_INDEX_BY_SHORT[$sibling_short]:-}" ]; then
        idx="${CHANNEL_INDEX_BY_SHORT[$sibling_short]}"
        if [ "$idx" != "$current_idx" ]; then
            printf '%s\n' "$idx"
            return 0
        fi
    fi

    for (( idx=0; idx<${#CHANNEL_SHORTS[@]}; idx++ )); do
        [ "$idx" -eq "$current_idx" ] && continue
        [ "${CHANNEL_CATEGORIES[$idx]}" = "$current_category" ] || continue
        printf '%s\n' "$idx"
        return 0
    done

    return 1
}

prompt_manual_url() {
    local raw_url

    echo ""
    read -rp "  Enter HLS URL: " raw_url
    raw_url="$(channels_trim "$raw_url")"
    if [ -z "$raw_url" ]; then
        echo -e "  ${R}✗ URL cannot be empty${NC}"
        return 1
    fi
    set_selected_manual_stream "$raw_url"
    return 0
}

print_stream_picker_menu() {
    local current_category=""
    local idx
    local suffix=""

    print_banner
    echo ""
    echo -e "  ${B}Select a stream:${NC}"
    echo ""

    for (( idx=0; idx<${#CHANNEL_SHORTS[@]}; idx++ )); do
        if [ "${CHANNEL_CATEGORIES[$idx]}" != "$current_category" ]; then
            [ -n "$current_category" ] && echo ""
            current_category="${CHANNEL_CATEGORIES[$idx]}"
            echo -e "  ${B}── ${current_category} ─────────────────────────────────${NC}"
        fi

        suffix=""
        [ "$idx" -eq 0 ] && suffix="  ${Y}★ default${NC}"
        printf "   %2d)  %-38s%s\n" "$((idx + 1))" "${CHANNEL_NAMES[$idx]}" "$suffix"
    done

    echo ""
    echo -e "  ${B}────────────────────────────────────────────────────${NC}"
    echo -e "   ${W}u)${NC}  Enter a URL manually"
    echo -e "   ${W}t)${NC}  Test all streams (check which are live)"
    echo ""
}

run_stream_probe_batch() {
    local input_file="$1"

    python3 - <<'PY' "$input_file" "$STREAM_TEST_TIMEOUT_SEC" "$STREAM_TEST_TOTAL_TIMEOUT_SEC" "$STREAM_TEST_MAX_PARALLEL"
import json
import subprocess
import sys
import time

input_path, per_timeout_raw, total_timeout_raw, max_parallel_raw = sys.argv[1:5]
per_timeout = float(per_timeout_raw)
total_timeout = float(total_timeout_raw)
max_parallel = int(max_parallel_raw)

def sanitize(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()

def bitrate_label(value):
    if not value:
        return ""
    try:
        numeric = int(float(value))
    except Exception:
        return ""
    if numeric >= 1_000_000:
        return f"{numeric / 1_000_000:.1f} Mbps"
    if numeric >= 1_000:
        return f"{numeric / 1_000:.0f} kbps"
    return f"{numeric} bps"

def resolution_label(video):
    width = video.get("width") or 0
    height = video.get("height") or 0
    try:
        width = int(width)
        height = int(height)
    except Exception:
        width = 0
        height = 0
    if height:
        return f"{height}p"
    if width and height:
        return f"{width}x{height}"
    return ""

def online_result(stdout_text):
    payload = json.loads(stdout_text)
    streams = payload.get("streams") or []
    fmt = payload.get("format") or {}
    video = next((stream for stream in streams if stream.get("codec_type") == "video"), {})
    resolution = resolution_label(video)
    bitrate = bitrate_label(fmt.get("bit_rate") or video.get("bit_rate") or "")
    summary_parts = [part for part in (resolution, bitrate) if part]
    summary = "  ".join(summary_parts) if summary_parts else "live"
    return ("online", resolution, bitrate, "", summary)

def offline_result(error):
    return ("offline", "", "", sanitize(error or "offline"), "")

entries = []
with open(input_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.rstrip("\n")
        if not line:
            continue
        idx, url, user_agent = line.split("\t")
        entries.append((int(idx), url, user_agent))

pending = list(entries)
running = {}
results = {}
deadline = time.monotonic() + total_timeout

while pending or running:
    now = time.monotonic()
    while pending and len(running) < max_parallel and now < deadline:
        idx, url, user_agent = pending.pop(0)
        cmd = ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams"]
        if user_agent:
            cmd.extend(["-user_agent", user_agent])
        cmd.extend(["-i", url])
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except FileNotFoundError:
            results[idx] = offline_result("ffprobe not found")
            now = time.monotonic()
            continue
        running[idx] = {"proc": proc, "started": time.monotonic()}
        now = time.monotonic()

    now = time.monotonic()
    finished = []
    for idx, meta in list(running.items()):
        proc = meta["proc"]
        timed_out = (now - meta["started"]) >= per_timeout or now >= deadline
        if proc.poll() is None and not timed_out:
            continue

        if proc.poll() is None:
            proc.kill()
        stdout_text, stderr_text = proc.communicate()

        if timed_out:
            results[idx] = offline_result("timeout")
        elif proc.returncode != 0 or not stdout_text.strip():
            error = stderr_text.strip().splitlines()[-1] if stderr_text.strip() else "probe failed"
            results[idx] = offline_result(error)
        else:
            try:
                results[idx] = online_result(stdout_text)
            except Exception as exc:
                results[idx] = offline_result(f"parse error: {exc}")
        finished.append(idx)

    for idx in finished:
        running.pop(idx, None)

    if time.monotonic() >= deadline:
        for idx, meta in list(running.items()):
            proc = meta["proc"]
            if proc.poll() is None:
                proc.kill()
            proc.communicate()
            results[idx] = offline_result("timeout")
            running.pop(idx, None)
        for idx, _url, _user_agent in pending:
            results[idx] = offline_result("timeout")
        pending = []
        break

    if running:
        time.sleep(0.1)

for idx in sorted(results):
    status, resolution, bitrate, error, summary = results[idx]
    print(
        f"{idx}\t{sanitize(status)}\t{sanitize(resolution)}\t{sanitize(bitrate)}\t{sanitize(error)}\t{sanitize(summary)}"
    )
PY
}

test_all_streams() {
    local current_category=""
    local input_file
    local result_file
    local idx
    local online_count=0
    local offline_count=0
    local status resolution bitrate error summary detail

    ensure_catalog_loaded || {
        echo -e "${R}✗ Failed to load channel catalog${NC}"
        return 1
    }
    ensure_selection_dependencies

    input_file=$(make_temp_file stream-batch)
    result_file=$(make_temp_file stream-results)
    track_temp_file "$input_file"
    track_temp_file "$result_file"

    : > "$input_file"
    for (( idx=0; idx<${#CHANNEL_SHORTS[@]}; idx++ )); do
        if [ -z "${STREAM_HEALTH_STATUS[$idx]:-}" ]; then
            if ua=$(channels_user_agent_from_notes "${CHANNEL_NOTES[$idx]}" 2>/dev/null); then
                printf '%s\t%s\t%s\n' "$idx" "${CHANNEL_URLS[$idx]}" "$ua" >> "$input_file"
            else
                printf '%s\t%s\t\n' "$idx" "${CHANNEL_URLS[$idx]}" >> "$input_file"
            fi
        fi
    done

    echo ""
    if [ -s "$input_file" ]; then
        echo -e "  ${D}Testing all streams... (this takes ~15 seconds)${NC}"
        run_stream_probe_batch "$input_file" > "$result_file"
        while IFS=$'\t' read -r idx status resolution bitrate error summary; do
            cache_stream_health_result "$idx" "${status}	${resolution}	${bitrate}	${error}	${summary}"
        done < "$result_file"
    else
        echo -e "  ${D}Using cached stream health from this session${NC}"
    fi

    echo ""
    for (( idx=0; idx<${#CHANNEL_SHORTS[@]}; idx++ )); do
        if [ "${CHANNEL_CATEGORIES[$idx]}" != "$current_category" ]; then
            [ -n "$current_category" ] && echo ""
            current_category="${CHANNEL_CATEGORIES[$idx]}"
            echo -e "  ${B}── ${current_category} ─────────────────────────────────${NC}"
        fi

        status="${STREAM_HEALTH_STATUS[$idx]:-offline}"
        resolution="${STREAM_HEALTH_RESOLUTION[$idx]:-}"
        bitrate="${STREAM_HEALTH_BITRATE[$idx]:-}"
        error="${STREAM_HEALTH_ERROR[$idx]:-offline}"
        summary="${STREAM_HEALTH_PROBE_SUMMARY[$idx]:-}"

        if [ "$status" = "online" ]; then
            online_count=$((online_count + 1))
            detail="${summary:-live}"
            printf "    ${G}✓${NC}  %-38s %s\n" "${CHANNEL_NAMES[$idx]}" "$detail"
        else
            offline_count=$((offline_count + 1))
            detail="${error:-offline}"
            printf "    ${R}✗${NC}  %-38s %s\n" "${CHANNEL_NAMES[$idx]}" "$detail"
        fi
    done

    echo ""
    echo -e "  ${#CHANNEL_SHORTS[@]} streams tested: ${online_count} online, ${offline_count} offline"
    return 0
}

validate_selected_stream() {
    local interactive_mode="${1:-0}"
    local force_refresh=0
    local alternate_index=""
    local error_message=""
    local choice=""

    ensure_selection_dependencies

    while true; do
        if probe_selected_stream_once "$force_refresh"; then
            STREAM_SELECTION_VALIDATED=1
            unset STREAM_HEALTH_ERROR["selected"]
            echo ""
            echo -e "  ${G}✓${NC} ${SELECTED_NAME}"
            [ -n "$SELECTED_PROBE_SUMMARY" ] && echo -e "    ${D}${SELECTED_PROBE_SUMMARY}${NC}"
            [ -n "$SELECTED_NOTES" ] && echo -e "    ${D}${SELECTED_NOTES}${NC}"
            echo ""
            return 0
        fi

        error_message="${STREAM_HEALTH_ERROR[selected]:-}"
        if [ -z "$error_message" ] && [ -n "$SELECTED_CATALOG_INDEX" ]; then
            error_message="${STREAM_HEALTH_ERROR[$SELECTED_CATALOG_INDEX]:-offline}"
        fi
        [ -n "$error_message" ] || error_message="offline"
        echo ""
        echo -e "  ${R}✗ ${SELECTED_NAME} appears to be offline${NC}"
        [ -n "$error_message" ] && echo -e "    ${D}${error_message}${NC}"

        if [ -n "$SELECTED_CATALOG_INDEX" ]; then
            alternate_index="$(suggest_alternate_stream_index "$SELECTED_CATALOG_INDEX" || true)"
        else
            alternate_index=""
        fi

        if [ "$interactive_mode" -ne 1 ] || [ ! -t 0 ]; then
            if [ -n "$alternate_index" ]; then
                echo -e "  ${D}Suggested alternate: ${CHANNEL_NAMES[$alternate_index]} (--stream ${CHANNEL_SHORTS[$alternate_index]})${NC}"
            fi
            return 1
        fi

        echo ""
        echo "  Options:"
        echo "    r)  Retry"
        if [ -n "$alternate_index" ]; then
            echo "    a)  Try alternate: ${CHANNEL_NAMES[$alternate_index]}"
        fi
        echo "    b)  Back to stream list"
        echo "    u)  Enter URL manually"
        echo ""

        if [ -n "$alternate_index" ]; then
            read -rp "  Select [r, a, b, u]: " choice
        else
            read -rp "  Select [r, b, u]: " choice
        fi
        choice="$(channels_short_key "$(channels_trim "$choice")")"

        case "$choice" in
            r|"")
                force_refresh=1
                ;;
            a)
                if [ -n "$alternate_index" ]; then
                    set_selected_stream_from_index "$alternate_index"
                    force_refresh=0
                fi
                ;;
            b)
                return 2
                ;;
            u)
                if prompt_manual_url; then
                    force_refresh=1
                fi
                ;;
            *)
                echo -e "  ${R}✗ Invalid choice${NC}"
                ;;
        esac
    done
}

select_stream_interactively() {
    local selection=""
    local selected_index=""
    local validation_rc=0

    ensure_catalog_loaded || {
        echo -e "${R}✗ Failed to load channel catalog${NC}"
        exit 1
    }

    while true; do
        print_stream_picker_menu
        read -rp "  Select [1-${#CHANNEL_SHORTS[@]}, u, t]: " selection
        selection="$(channels_trim "$selection")"

        if [ -z "$selection" ]; then
            set_selected_stream_from_index 0
        else
            case "$(channels_short_key "$selection")" in
                u)
                    prompt_manual_url || continue
                    ;;
                t)
                    test_all_streams
                    echo ""
                    read -rp "  Press Enter to return to stream selection... " _
                    continue
                    ;;
                *)
                    if selected_index=$(resolve_stream_index "$selection"); then
                        set_selected_stream_from_index "$selected_index"
                    else
                        echo ""
                        echo -e "  ${R}✗ Unknown stream selection: ${selection}${NC}"
                        sleep 1
                        continue
                    fi
                    ;;
            esac
        fi

        validate_selected_stream 1
        validation_rc=$?
        if [ "$validation_rc" -eq 0 ]; then
            return 0
        fi
        if [ "$validation_rc" -eq 2 ]; then
            continue
        fi
    done
}

initialize_stream_selection() {
    local selected_index=""

    if [ -n "$MASTER_URL" ]; then
        set_selected_manual_stream "$MASTER_URL" "Direct URL" "direct-url"
        return 0
    fi

    if [ -n "$STREAM_SELECTOR" ]; then
        ensure_catalog_loaded || {
            echo -e "${R}✗ Failed to load channel catalog${NC}"
            exit 1
        }
        if ! selected_index=$(resolve_stream_index "$STREAM_SELECTOR"); then
            echo -e "${R}✗ Unknown stream selector: ${STREAM_SELECTOR}${NC}"
            exit 1
        fi
        set_selected_stream_from_index "$selected_index"
        return 0
    fi

    ensure_catalog_loaded || {
        echo -e "${R}✗ Failed to load channel catalog${NC}"
        exit 1
    }

    if [ ! -t 0 ]; then
        set_selected_stream_from_index 0
        echo -e "  ${D}No interactive stream input detected — defaulting to ${SELECTED_NAME}${NC}"
        return 0
    fi

    select_stream_interactively
}

format_seg_num() {
    printf '%06d' "$1"
}

format_elapsed_compact() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    if [ "$hours" -gt 0 ]; then
        printf '%dh %02dm' "$hours" "$minutes"
    else
        printf '%dm %02ds' "$minutes" "$((seconds % 60))"
    fi
}

monitor_log() {
    [ -n "$MONITOR_LOG_FILE" ] || return 0
    printf '[%s] %s\n' "$(timestamp_now)" "$1" >> "$MONITOR_LOG_FILE"
}

monitor_append_unique_line() {
    local current="$1"
    local value="$2"
    local line
    while IFS= read -r line; do
        [ "$line" = "$value" ] && {
            printf '%s' "$current"
            return 0
        }
    done <<EOF
$current
EOF
    if [ -n "$current" ]; then
        printf '%s\n%s' "$current" "$value"
    else
        printf '%s' "$value"
    fi
}

monitor_keywords_display() {
    local raw="$1"
    python3 - <<'PY' "$raw"
import sys
lines = [line.strip() for line in sys.argv[1].splitlines() if line.strip()]
print(", ".join(lines))
PY
}

monitor_pending_dir() {
    printf '%s/match_%03d_pending' "$MONITOR_KEPT_DIR" "$1"
}

monitor_final_dir() {
    local match_id="$1"
    printf '%s/match_%03d_seg_%s-%s' \
        "$MONITOR_KEPT_DIR" \
        "$match_id" \
        "$(format_seg_num "${MONITOR_MATCH_START[$match_id]}")" \
        "$(format_seg_num "${MONITOR_MATCH_END[$match_id]}")"
}

monitor_write_match_info() {
    local match_id="$1"
    local target_dir="$2"
    mkdir -p "$target_dir"
    {
        echo "Experimental keyword monitor match"
        echo "Match ID: ${match_id}"
        echo "Segment range: $(format_seg_num "${MONITOR_MATCH_START[$match_id]}")-$(format_seg_num "${MONITOR_MATCH_END[$match_id]}")"
        echo "Detected: ${MONITOR_MATCH_FIRST_TS[$match_id]}"
        echo "Keywords:"
        printf '%s\n' "${MONITOR_MATCH_KEYWORDS[$match_id]}"
        echo ""
        echo "Hit details:"
        printf '%s\n' "${MONITOR_MATCH_HITS[$match_id]}"
    } > "${target_dir}/match_info.txt"
}

monitor_merge_matches() {
    local primary="$1"
    local secondary="$2"
    local seg_id
    local secondary_dir
    local primary_dir

    [ "$primary" = "$secondary" ] && return 0
    [ -n "${MONITOR_MATCH_START[$secondary]:-}" ] || return 0

    if [ "${MONITOR_MATCH_START[$secondary]}" -lt "${MONITOR_MATCH_START[$primary]}" ]; then
        MONITOR_MATCH_START[$primary]="${MONITOR_MATCH_START[$secondary]}"
    fi
    if [ "${MONITOR_MATCH_END[$secondary]}" -gt "${MONITOR_MATCH_END[$primary]}" ]; then
        MONITOR_MATCH_END[$primary]="${MONITOR_MATCH_END[$secondary]}"
    fi
    while IFS= read -r keyword; do
        [ -n "$keyword" ] || continue
        MONITOR_MATCH_KEYWORDS[$primary]="$(monitor_append_unique_line "${MONITOR_MATCH_KEYWORDS[$primary]:-}" "$keyword")"
    done <<EOF
${MONITOR_MATCH_KEYWORDS[$secondary]:-}
EOF
    if [ -n "${MONITOR_MATCH_HITS[$secondary]:-}" ]; then
        if [ -n "${MONITOR_MATCH_HITS[$primary]:-}" ]; then
            MONITOR_MATCH_HITS[$primary]="${MONITOR_MATCH_HITS[$primary]}
${MONITOR_MATCH_HITS[$secondary]}"
        else
            MONITOR_MATCH_HITS[$primary]="${MONITOR_MATCH_HITS[$secondary]}"
        fi
    fi

    secondary_dir="${MONITOR_MATCH_DIR[$secondary]:-$(monitor_pending_dir "$secondary")}"
    primary_dir="${MONITOR_MATCH_DIR[$primary]:-$(monitor_pending_dir "$primary")}"
    if [ -d "$secondary_dir" ]; then
        mkdir -p "$primary_dir"
        while IFS= read -r -d '' item; do
            mv "$item" "$primary_dir"/
        done < <(find "$secondary_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        rmdir "$secondary_dir" 2>/dev/null || true
        MONITOR_MATCH_DIR[$primary]="$primary_dir"
    fi

    for seg_id in "${!MONITOR_FLAGGED_SEGMENTS[@]}"; do
        [ "${MONITOR_FLAGGED_SEGMENTS[$seg_id]}" = "$secondary" ] && MONITOR_FLAGGED_SEGMENTS[$seg_id]="$primary"
    done

    unset MONITOR_MATCH_START["$secondary"]
    unset MONITOR_MATCH_END["$secondary"]
    unset MONITOR_MATCH_KEYWORDS["$secondary"]
    unset MONITOR_MATCH_FIRST_TS["$secondary"]
    unset MONITOR_MATCH_HITS["$secondary"]
    unset MONITOR_MATCH_DIR["$secondary"]
    unset MONITOR_MATCH_FINALIZED["$secondary"]
    monitor_log "Merged overlapping match ${secondary} into match ${primary}"
}

monitor_register_match() {
    local segment_number="$1"
    local keyword="$2"
    local matched_line="$3"
    local buffer_depth="$4"
    local range_start="$((segment_number - buffer_depth))"
    local range_end="$((segment_number + buffer_depth))"
    local match_id=0
    local existing_id
    local extra_ids=()
    local seg

    [ "$range_start" -lt 1 ] && range_start=1

    for (( existing_id=1; existing_id<NEXT_MONITOR_MATCH_ID; existing_id++ )); do
        [ -n "${MONITOR_MATCH_START[$existing_id]:-}" ] || continue
        if [ "$range_start" -le $((MONITOR_MATCH_END[$existing_id] + 1)) ] && [ "$range_end" -ge $((MONITOR_MATCH_START[$existing_id] - 1)) ]; then
            if [ "$match_id" -eq 0 ]; then
                match_id="$existing_id"
            else
                extra_ids+=("$existing_id")
            fi
        fi
    done

    if [ "$match_id" -eq 0 ]; then
        match_id="$NEXT_MONITOR_MATCH_ID"
        NEXT_MONITOR_MATCH_ID=$((NEXT_MONITOR_MATCH_ID + 1))
        MONITOR_MATCHES_FOUND=$((MONITOR_MATCHES_FOUND + 1))
        MONITOR_MATCH_START[$match_id]="$range_start"
        MONITOR_MATCH_END[$match_id]="$range_end"
        MONITOR_MATCH_FIRST_TS[$match_id]="$(timestamp_now)"
        MONITOR_MATCH_KEYWORDS[$match_id]="$keyword"
        MONITOR_MATCH_HITS[$match_id]="[$(timestamp_now)] ${keyword} :: ${matched_line}"
        MONITOR_MATCH_FINALIZED[$match_id]=0
    else
        if [ "$range_start" -lt "${MONITOR_MATCH_START[$match_id]}" ]; then
            MONITOR_MATCH_START[$match_id]="$range_start"
        fi
        if [ "$range_end" -gt "${MONITOR_MATCH_END[$match_id]}" ]; then
            MONITOR_MATCH_END[$match_id]="$range_end"
        fi
        MONITOR_MATCH_KEYWORDS[$match_id]="$(monitor_append_unique_line "${MONITOR_MATCH_KEYWORDS[$match_id]:-}" "$keyword")"
        if [ -n "${MONITOR_MATCH_HITS[$match_id]:-}" ]; then
            MONITOR_MATCH_HITS[$match_id]="${MONITOR_MATCH_HITS[$match_id]}
[$(timestamp_now)] ${keyword} :: ${matched_line}"
        else
            MONITOR_MATCH_HITS[$match_id]="[$(timestamp_now)] ${keyword} :: ${matched_line}"
        fi
    fi

    for existing_id in "${extra_ids[@]}"; do
        monitor_merge_matches "$match_id" "$existing_id"
    done

    for (( seg=range_start; seg<=range_end; seg++ )); do
        MONITOR_FLAGGED_SEGMENTS[$seg]="$match_id"
    done

    printf '%s\n' "$match_id"
}

monitor_cleanup_buffer_segment() {
    local seg="$1"
    local reason="${2:-buffer expired}"
    rm -f "${MONITOR_SEG_MP4[$seg]:-}" "${MONITOR_SEG_SRT[$seg]:-}" "${MONITOR_SEG_TXT[$seg]:-}"
    unset MONITOR_SEG_MP4["$seg"]
    unset MONITOR_SEG_SRT["$seg"]
    unset MONITOR_SEG_TXT["$seg"]
    monitor_log "SEG $(format_seg_num "$seg") DELETED (${reason})"
}

monitor_promote_segment() {
    local seg="$1"
    local match_id="${MONITOR_FLAGGED_SEGMENTS[$seg]:-}"
    local pending_dir

    [ -n "$match_id" ] || return 0
    pending_dir="${MONITOR_MATCH_DIR[$match_id]:-$(monitor_pending_dir "$match_id")}"
    mkdir -p "$pending_dir"
    MONITOR_MATCH_DIR[$match_id]="$pending_dir"

    [ -f "${MONITOR_SEG_MP4[$seg]:-}" ] && mv "${MONITOR_SEG_MP4[$seg]}" "$pending_dir"/
    [ -f "${MONITOR_SEG_SRT[$seg]:-}" ] && mv "${MONITOR_SEG_SRT[$seg]}" "$pending_dir"/
    [ -f "${MONITOR_SEG_TXT[$seg]:-}" ] && mv "${MONITOR_SEG_TXT[$seg]}" "$pending_dir"/
    monitor_log "SEG $(format_seg_num "$seg") PROMOTED to $(basename "$pending_dir")/"
    unset MONITOR_SEG_MP4["$seg"]
    unset MONITOR_SEG_SRT["$seg"]
    unset MONITOR_SEG_TXT["$seg"]
}

monitor_finalize_match_dir() {
    local match_id="$1"
    local pending_dir="${MONITOR_MATCH_DIR[$match_id]:-$(monitor_pending_dir "$match_id")}"
    local final_dir

    [ -n "${MONITOR_MATCH_START[$match_id]:-}" ] || return 0
    final_dir="$(monitor_final_dir "$match_id")"
    mkdir -p "$final_dir"
    if [ -d "$pending_dir" ]; then
        while IFS= read -r -d '' item; do
            mv "$item" "$final_dir"/
        done < <(find "$pending_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        if [ "$pending_dir" != "$final_dir" ]; then
            rmdir "$pending_dir" 2>/dev/null || true
        fi
    fi
    monitor_write_match_info "$match_id" "$final_dir"
    MONITOR_MATCH_DIR[$match_id]="$final_dir"
    MONITOR_MATCH_FINALIZED[$match_id]=1
    MONITOR_LAST_MATCH_SUMMARY="#${match_id}  seg $(format_seg_num "${MONITOR_MATCH_START[$match_id]}")-$(format_seg_num "${MONITOR_MATCH_END[$match_id]}")"
    monitor_log "MATCH ${match_id} FINALIZED → $(basename "$final_dir")"
}

monitor_finalize_ready_matches() {
    local current_seg="$1"
    local force="${2:-0}"
    local match_id

    for (( match_id=1; match_id<NEXT_MONITOR_MATCH_ID; match_id++ )); do
        [ -n "${MONITOR_MATCH_START[$match_id]:-}" ] || continue
        [ "${MONITOR_MATCH_FINALIZED[$match_id]:-0}" -eq 1 ] && continue
        if [ "$force" -eq 1 ] || [ "$current_seg" -gt $((MONITOR_MATCH_END[$match_id] + MONITOR_BUFFER_DEPTH)) ]; then
            monitor_finalize_match_dir "$match_id"
        fi
    done
}

monitor_finalize_flagged_segments() {
    local seg
    for (( seg=1; seg<=MONITOR_LAST_SEGMENT_RECORDED; seg++ )); do
        if [ -n "${MONITOR_SEG_MP4[$seg]:-}" ] && [ -n "${MONITOR_FLAGGED_SEGMENTS[$seg]:-}" ]; then
            monitor_promote_segment "$seg"
        fi
    done
}

monitor_clean_cc_text() {
    local srt_file="$1"
    local txt_file="$2"
    python3 - <<'PY' "$srt_file" "$txt_file"
import re
import sys

srt_path, txt_path = sys.argv[1:3]
text_lines = []
try:
    with open(srt_path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if line.isdigit():
                continue
            if "-->" in line:
                continue
            line = re.sub(r"^>+\s*", "", line)
            line = re.sub(r"^[A-Z][A-Z0-9 .&'/:-]{1,40}:\s*", "", line)
            line = re.sub(r"\s+", " ", line).strip()
            if line:
                text_lines.append(line)
except FileNotFoundError:
    pass

with open(txt_path, "w", encoding="utf-8") as fh:
    if text_lines:
        fh.write("\n".join(text_lines) + "\n")
PY
}

monitor_detect_keyword_hit() {
    local txt_file="$1"
    local keywords_file="$2"
    python3 - <<'PY' "$txt_file" "$keywords_file"
import sys

txt_path, keywords_path = sys.argv[1:3]
try:
    with open(keywords_path, "r", encoding="utf-8", errors="replace") as fh:
        keywords = [line.strip() for line in fh if line.strip()]
except FileNotFoundError:
    sys.exit(1)

try:
    with open(txt_path, "r", encoding="utf-8", errors="replace") as fh:
        lines = [line.strip() for line in fh if line.strip()]
except FileNotFoundError:
    sys.exit(1)

lowered_keywords = [(kw, kw.lower()) for kw in keywords]
for line in lines:
    low_line = line.lower()
    for original, low_kw in lowered_keywords:
        if low_kw in low_line:
            print(f"{original}\t{line}")
            sys.exit(0)
sys.exit(1)
PY
}

monitor_try_live_cc_method() {
    local method="$1"
    local out_file="$2"
    local duration="$3"
    local log_file="$4"
    case "$method" in
        subtitle-map)
            ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$MASTER_URL" -t "$duration" -map 0:s:0? -c:s srt "$out_file" \
                > /dev/null 2>"$log_file"
            ;;
        subtitle-codec-map)
            ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$MONITOR_BEST_URL" -t "$duration" -codec:s srt -map 0:s? "$out_file" \
                > /dev/null 2>"$log_file"
            ;;
        *)
            return 1
            ;;
    esac
}

monitor_extract_cc_from_file() {
    local method="$1"
    local input_file="$2"
    local out_file="$3"
    local log_file="$4"
    case "$method" in
        lavfi-subcc)
            ffmpeg -y -f lavfi -i "movie=${input_file}[out+subcc]" -map 0:s -c:s srt "$out_file" \
                > /dev/null 2>"$log_file"
            ;;
        extractcc-filter)
            if ffmpeg -hide_banner -filters | grep -q ' extractcc '; then
                ffmpeg -y -i "$input_file" -filter_complex "[0:v]extractcc[sub]" -map "[sub]" -c:s srt "$out_file" \
                    > /dev/null 2>"$log_file"
            else
                printf 'extractcc filter not available in this ffmpeg build.\n' > "$log_file"
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

monitor_refresh_stream_targets() {
    local refreshed_content refreshed_best refreshed_summary
    refreshed_content=$(curl -fsSL -A "$ACTIVE_HTTP_USER_AGENT" "$MASTER_URL" 2>/dev/null) || return 1
    MONITOR_HAS_CC_DECLARED=0
    MONITOR_HAS_SUBTITLE_DECLARED=0
    echo "$refreshed_content" | grep -q 'TYPE=CLOSED-CAPTIONS' && MONITOR_HAS_CC_DECLARED=1
    echo "$refreshed_content" | grep -q 'TYPE=SUBTITLES' && MONITOR_HAS_SUBTITLE_DECLARED=1
    refreshed_best=$(echo "$refreshed_content" | python3 - <<'PY' "$MASTER_URL"
import sys
from urllib.parse import urljoin

master_url = sys.argv[1]
lines = sys.stdin.read().strip().splitlines()
variants = []
i = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith("#EXT-X-STREAM-INF:"):
        attrs = line.split(":", 1)[1]
        bandwidth = 0
        for part in attrs.split(","):
            part = part.strip()
            if part.startswith("BANDWIDTH="):
                try:
                    bandwidth = int(part.split("=", 1)[1])
                except ValueError:
                    bandwidth = 0
        j = i + 1
        while j < len(lines) and lines[j].strip().startswith("#"):
            j += 1
        if j < len(lines):
            variants.append((bandwidth, urljoin(master_url, lines[j].strip())))
        i = j
    i += 1

variants.sort(reverse=True)
print(variants[0][1] if variants else "")
PY
)
    [ -n "$refreshed_best" ] || return 1
    MONITOR_BEST_URL="$refreshed_best"
    refreshed_summary=$(ffprobe -user_agent "$ACTIVE_HTTP_USER_AGENT" -v quiet -print_format json -show_format -show_streams -i "$MONITOR_BEST_URL" 2>/dev/null \
        | python3 - <<'PY'
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

video = next((stream for stream in data.get("streams", []) if stream.get("codec_type") == "video"), None)
fmt = data.get("format") or {}
if not video:
    sys.exit(0)
codec = video.get("codec_name", "?")
width = video.get("width", "?")
height = video.get("height", "?")
bit_rate = fmt.get("bit_rate") or video.get("bit_rate") or ""
bit_rate_txt = ""
if bit_rate:
    try:
        bit_rate_txt = f" @ {int(bit_rate)//1000} kbps"
    except Exception:
        bit_rate_txt = ""
print(f"{width}x{height} {codec}{bit_rate_txt}")
PY
)
    [ -n "$refreshed_summary" ] && MONITOR_STREAM_SUMMARY="$refreshed_summary"
    return 0
}

monitor_detect_cc_method() {
    local requested_method="$1"
    local diag_sec=12
    local temp_dir live_srt live_log sample_ts sample_log file_srt file_log

    if [ "$requested_method" != "auto" ]; then
        printf '%s\n' "$requested_method"
        return 0
    fi

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/monitor-cc.XXXXXX")"
    track_temp_file "$temp_dir"

    live_srt="${temp_dir}/subtitle-map.srt"
    live_log="${temp_dir}/subtitle-map.log"
    if monitor_try_live_cc_method "subtitle-map" "$live_srt" "$diag_sec" "$live_log" && [ -s "$live_srt" ]; then
        printf 'subtitle-map\n'
        return 0
    fi

    live_srt="${temp_dir}/subtitle-codec-map.srt"
    live_log="${temp_dir}/subtitle-codec-map.log"
    if monitor_try_live_cc_method "subtitle-codec-map" "$live_srt" "$diag_sec" "$live_log" && [ -s "$live_srt" ]; then
        printf 'subtitle-codec-map\n'
        return 0
    fi

    sample_ts="${temp_dir}/sample.ts"
    sample_log="${temp_dir}/sample.log"
    if ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$MONITOR_BEST_URL" -t "$diag_sec" -map 0:v:0 -map 0:a? -c copy -f mpegts "$sample_ts" \
        > /dev/null 2>"$sample_log"; then
        file_srt="${temp_dir}/lavfi-subcc.srt"
        file_log="${temp_dir}/lavfi-subcc.log"
        if monitor_extract_cc_from_file "lavfi-subcc" "$sample_ts" "$file_srt" "$file_log" && [ -s "$file_srt" ]; then
            printf 'lavfi-subcc\n'
            return 0
        fi

        file_srt="${temp_dir}/extractcc-filter.srt"
        file_log="${temp_dir}/extractcc-filter.log"
        if monitor_extract_cc_from_file "extractcc-filter" "$sample_ts" "$file_srt" "$file_log" && [ -s "$file_srt" ]; then
            printf 'extractcc-filter\n'
            return 0
        fi
    fi

    printf 'none\n'
}

monitor_render_status() {
    local elapsed buffer_count buffer_limit buffer_bytes kept_bytes preview status_lines
    local match_id start end keyword summary_line

    if [ "$QUIET" -eq 1 ] || [ ! -t 1 ]; then
        return 0
    fi

    elapsed=$(( $(date +%s) - MONITOR_START_EPOCH ))
    buffer_count=0
    for _ in "${!MONITOR_SEG_MP4[@]}"; do
        buffer_count=$((buffer_count + 1))
    done
    buffer_limit=$((MONITOR_BUFFER_DEPTH * 2 + 1))
    buffer_bytes=$(sum_dir_bytes "$MONITOR_BUFFER_DIR")
    kept_bytes=$(sum_dir_bytes "$MONITOR_KEPT_DIR")
    preview="${MONITOR_LAST_CC_PREVIEW:-"(no caption text yet)"}"

    if [ "$MONITOR_STATUS_LINES" -gt 0 ]; then
        printf '\033[%dA' "$MONITOR_STATUS_LINES"
    fi
    printf '\033[J'

    status_lines=0
    echo -e "  ${BG_Y} MONITOR ${NC}  ${B}segment #${MONITOR_LAST_SEGMENT_RECORDED}${NC}  ${D}$(format_elapsed_compact "$elapsed") elapsed${NC}  ${B}${MONITOR_MATCHES_FOUND} matches${NC}"
    status_lines=$((status_lines + 1))
    echo -e "  Buffer: [$(draw_bar $(( buffer_count * 100 / (buffer_limit > 0 ? buffer_limit : 1) )) 10)] ${buffer_count}/${buffer_limit} slots    Disk: $(human_size "$buffer_bytes") (buffer) + $(human_size "$kept_bytes") (kept)"
    status_lines=$((status_lines + 1))
    echo -e "  CC Method: ${MONITOR_CC_METHOD}    Last CC: \"${preview:0:80}\""
    status_lines=$((status_lines + 1))
    echo "  Matches:"
    status_lines=$((status_lines + 1))
    for (( match_id=NEXT_MONITOR_MATCH_ID-1; match_id>=1 && match_id>=NEXT_MONITOR_MATCH_ID-3; match_id-- )); do
        [ -n "${MONITOR_MATCH_START[$match_id]:-}" ] || continue
        start="$(format_seg_num "${MONITOR_MATCH_START[$match_id]}")"
        end="$(format_seg_num "${MONITOR_MATCH_END[$match_id]}")"
        keyword="$(printf '%s\n' "${MONITOR_MATCH_KEYWORDS[$match_id]}" | head -n 1)"
        summary_line="    #${match_id}  seg ${start}-${end}  \"${keyword}\"  ${MONITOR_MATCH_FIRST_TS[$match_id]}"
        if [ "${MONITOR_MATCH_FINALIZED[$match_id]:-0}" -eq 1 ]; then
            summary_line="${summary_line}  → $(basename "${MONITOR_MATCH_DIR[$match_id]}")/"
        else
            summary_line="${summary_line}  → pending"
        fi
        echo "$summary_line"
        status_lines=$((status_lines + 1))
    done
    MONITOR_STATUS_LINES="$status_lines"
}

monitor_force_flush_buffer() {
    local seg
    for (( seg=1; seg<=MONITOR_LAST_SEGMENT_RECORDED; seg++ )); do
        [ -n "${MONITOR_SEG_MP4[$seg]:-}" ] || continue
        if [ -n "${MONITOR_FLAGGED_SEGMENTS[$seg]:-}" ]; then
            monitor_promote_segment "$seg"
        else
            monitor_cleanup_buffer_segment "$seg" "low disk flush"
        fi
    done
}

monitor_disk_guard() {
    local free_kb

    free_kb=$(disk_free_kb "$OUT_DIR")
    [ -n "$free_kb" ] || return 0

    if [ "$free_kb" -lt 1048576 ]; then
        monitor_log "WARNING: disk below 1 GB free — forcing buffer flush"
        monitor_force_flush_buffer
    fi

    free_kb=$(disk_free_kb "$OUT_DIR")
    while [ -n "$free_kb" ] && [ "$free_kb" -lt 512000 ]; do
        monitor_log "WARNING: disk below 500 MB free — pausing recording"
        echo -e "  ${R}⚠ Disk space below 500 MB. Monitor mode paused until space recovers.${NC}"
        sleep 30
        free_kb=$(disk_free_kb "$OUT_DIR")
    done
}

monitor_record_segment() {
    local seg="$1"
    local mp4_file="${MONITOR_BUFFER_DIR}/seg_$(format_seg_num "$seg").mp4"
    local srt_file="${MONITOR_BUFFER_DIR}/seg_$(format_seg_num "$seg").srt"
    local txt_file="${MONITOR_BUFFER_DIR}/seg_$(format_seg_num "$seg").txt"
    local vlog clog stall_marker watchdog_pid video_pid cc_pid kp cc_lines bytes matched keyword line match_id

    vlog=$(make_temp_file monitor-vid)
    clog=$(make_temp_file monitor-cc)
    stall_marker=$(make_temp_file monitor-stall)
    track_temp_file "$vlog"
    track_temp_file "$clog"
    track_temp_file "$stall_marker"

    ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$MONITOR_BEST_URL" -t "$MONITOR_SEGMENT_SEC" \
        -c:v copy -c:a copy -movflags +faststart -loglevel warning -stats \
        "$mp4_file" 2>"$vlog" &
    video_pid=$!
    track_pid "$video_pid"
    watchdog_pid=$(start_timeout_watchdog "$video_pid" "$((MONITOR_SEGMENT_SEC * SEGMENT_TIMEOUT_MULTIPLIER))" "$stall_marker")
    track_pid "$watchdog_pid"

    cc_pid=""
    case "$MONITOR_CC_METHOD" in
        subtitle-map)
            ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$MASTER_URL" -t "$MONITOR_SEGMENT_SEC" -map 0:s:0? -c:s srt "$srt_file" \
                > /dev/null 2>"$clog" &
            cc_pid=$!
            track_pid "$cc_pid"
            ;;
        subtitle-codec-map)
            ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$MONITOR_BEST_URL" -t "$MONITOR_SEGMENT_SEC" -codec:s srt -map 0:s? "$srt_file" \
                > /dev/null 2>"$clog" &
            cc_pid=$!
            track_pid "$cc_pid"
            ;;
    esac

    while kill -0 "$video_pid" 2>/dev/null; do
        sleep 1
    done

    wait "$video_pid"; VEC=$?
    forget_pid "$video_pid"
    stop_timeout_watchdog "$watchdog_pid"

    if [ -n "$cc_pid" ]; then
        ( sleep 8; kill "$cc_pid" 2>/dev/null ) &
        kp=$!
        wait "$cc_pid" 2>/dev/null || true
        forget_pid "$cc_pid"
        kill "$kp" 2>/dev/null || true
        wait "$kp" 2>/dev/null || true
    fi

    if [ "$VEC" -ne 0 ] || [ ! -s "$mp4_file" ]; then
        if [ -s "$stall_marker" ]; then
            monitor_log "WARNING: SEG $(format_seg_num "$seg") hit timeout while recording"
        fi
        rm -f "$mp4_file" "$srt_file" "$txt_file"
        forget_temp_file "$vlog"
        forget_temp_file "$clog"
        forget_temp_file "$stall_marker"
        rm -f "$vlog" "$clog" "$stall_marker"
        monitor_log "SEG $(format_seg_num "$seg") failed — waiting 10s before reconnect"
        sleep 10
        if monitor_refresh_stream_targets; then
            monitor_log "STREAM REFRESH OK — resumed with ${MONITOR_BEST_URL}"
        else
            monitor_log "WARNING: stream refresh failed after segment error"
        fi
        return 1
    fi

    case "$MONITOR_CC_METHOD" in
        lavfi-subcc|extractcc-filter)
            monitor_extract_cc_from_file "$MONITOR_CC_METHOD" "$mp4_file" "$srt_file" "$clog" || true
            ;;
        none)
            : > "$srt_file"
            ;;
    esac

    [ -f "$srt_file" ] || : > "$srt_file"
    monitor_clean_cc_text "$srt_file" "$txt_file"

    MONITOR_SEG_MP4[$seg]="$mp4_file"
    MONITOR_SEG_SRT[$seg]="$srt_file"
    MONITOR_SEG_TXT[$seg]="$txt_file"
    bytes=$(file_size_bytes "$mp4_file" 2>/dev/null || printf '0')
    cc_lines=$(count_nonempty_lines "$txt_file")
    monitor_log "SEG $(format_seg_num "$seg") recorded — $(human_size "$bytes") — CC: ${cc_lines} lines"

    if [ "$cc_lines" -gt 0 ]; then
        MONITOR_EMPTY_CC_STREAK=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            monitor_log "SEG $(format_seg_num "$seg") CC: $line"
            MONITOR_LAST_CC_PREVIEW="$line"
        done < "$txt_file"
    else
        MONITOR_EMPTY_CC_STREAK=$((MONITOR_EMPTY_CC_STREAK + 1))
        MONITOR_LAST_CC_PREVIEW="(no caption text)"
        if [ "$MONITOR_EMPTY_CC_STREAK" -eq 10 ]; then
            monitor_log "WARNING: CC stream appears to have gone silent"
        fi
    fi

    if [ "$MONITOR_CC_METHOD" != "none" ] && matched=$(monitor_detect_keyword_hit "$txt_file" "$MONITOR_KEYWORDS_FILE"); then
        keyword="${matched%%	*}"
        line="${matched#*	}"
        match_id=$(monitor_register_match "$seg" "$keyword" "$line" "$MONITOR_BUFFER_DEPTH")
        monitor_log "★ KEYWORD HIT in SEG $(format_seg_num "$seg"): \"${keyword}\" — line: \"${line}\""
        monitor_log "FLAGGED segments $(format_seg_num "${MONITOR_MATCH_START[$match_id]}")-$(format_seg_num "${MONITOR_MATCH_END[$match_id]}") for retention"
    else
        monitor_log "SEG $(format_seg_num "$seg") — no keyword match — buffer OK"
    fi

    rm -f "$vlog" "$clog" "$stall_marker"
    forget_temp_file "$vlog"
    forget_temp_file "$clog"
    forget_temp_file "$stall_marker"
    return 0
}

monitor_print_summary() {
    local kept_dirs
    kept_dirs=$(find "$MONITOR_KEPT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo ""
    echo -e "${C}${B}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${C}${B}║  Keyword Monitor Complete — $(date +%H:%M:%S)                 ║${NC}"
    echo -e "${C}${B}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${B}Stream${NC}      ${SELECTED_NAME}"
    echo -e "  ${B}Segments${NC}    ${MONITOR_LAST_SEGMENT_RECORDED}"
    echo -e "  ${B}Matches${NC}     ${MONITOR_MATCHES_FOUND}"
    echo -e "  ${B}Kept folders${NC} ${kept_dirs}"
    echo -e "  ${B}Location${NC}    ${OUT_DIR}/"
    MONITOR_SUMMARY_PRINTED=1
}

monitor_cleanup_on_exit() {
    local exit_code="$1"
    [ "$MONITOR_ACTIVE" -eq 1 ] || return 0
    [ "$MONITOR_SUMMARY_PRINTED" -eq 0 ] || return 0

    if [ "$MONITOR_INTERRUPTED" -eq 1 ]; then
        monitor_log "MONITOR INTERRUPTED — promoting flagged buffer segments before exit"
        monitor_log "BUFFER PRESERVED — unflagged segments left in buffer/ for manual review"
    elif [ "$exit_code" -ne 0 ]; then
        monitor_log "MONITOR EXITED WITH ERROR (${exit_code}) — promoting flagged buffer segments before exit"
    else
        return 0
    fi
    monitor_finalize_flagged_segments
    monitor_finalize_ready_matches "$((MONITOR_LAST_SEGMENT_RECORDED + MONITOR_BUFFER_DEPTH + 1))" 1
    monitor_print_summary
    return "$exit_code"
}

run_keyword_monitor() {
    local keyword_count selected_method choice check_seg

    MONITOR_ACTIVE=1
    MONITOR_START_EPOCH=$(date +%s)
    MONITOR_BUFFER_DEPTH=$(((MONITOR_BUFFER_SEC + MONITOR_SEGMENT_SEC - 1) / MONITOR_SEGMENT_SEC))
    [ -z "$OUTPUT_OVERRIDE" ] && OUT_DIR="$DEFAULT_MONITOR_OUTPUT_DIR"
    MONITOR_BUFFER_DIR="${OUT_DIR}/buffer"
    MONITOR_KEPT_DIR="${OUT_DIR}/kept"
    MONITOR_LOG_FILE="${OUT_DIR}/monitor.log"
    mkdir -p "$MONITOR_BUFFER_DIR" "$MONITOR_KEPT_DIR"

    if [ ! -f "$MONITOR_KEYWORDS_FILE" ]; then
        echo -e "${R}✗ Keywords file not found: ${MONITOR_KEYWORDS_FILE}${NC}"
        return 1
    fi
    keyword_count=$(grep -c '[^[:space:]]' "$MONITOR_KEYWORDS_FILE" 2>/dev/null || printf '0')

    MONITOR_BEST_URL="$BEST_URL"
    monitor_refresh_stream_targets || true
    MONITOR_STREAM_SUMMARY="${MONITOR_STREAM_SUMMARY:-1080p stream}"

    echo -e "  ${Y}${B}⚡ KEYWORD MONITOR MODE (experimental)${NC}"
    echo ""
    echo -e "  ${B}Keywords${NC}    $(monitor_keywords_display "$(cat "$MONITOR_KEYWORDS_FILE")")"
    echo -e "  ${B}Source${NC}      $(basename "$MONITOR_KEYWORDS_FILE") (${keyword_count} phrases)"
    echo -e "  ${B}Buffer${NC}      ${MONITOR_BUFFER_MINUTES} min before + ${MONITOR_BUFFER_MINUTES} min after match"
    echo -e "  ${B}Segments${NC}    $((MONITOR_SEGMENT_SEC / 60)).$(( (MONITOR_SEGMENT_SEC % 60) / 10 )) min each"
    echo -e "  ${B}Run until${NC}   ${MONITOR_UNTIL_RAW:-Ctrl+C}"
    echo ""
    echo -e "  ${Y}⚠ This mode requires working closed captions.${NC}"
    echo -e "    Running CC diagnostic first..."

    selected_method=$(monitor_detect_cc_method "$MONITOR_CC_METHOD")
    MONITOR_CC_METHOD="$selected_method"
    if [ "$MONITOR_CC_METHOD" = "none" ]; then
        echo -e "    ${Y}⚠ No closed captions detected — keyword monitoring will not work${NC}"
        echo -e "    ${D}This stream advertises CC metadata, but ffmpeg did not decode usable text in the diagnostic.${NC}"
        monitor_log "WARNING: No closed captions detected — keyword monitoring will not work"
        if [ -t 0 ] && [ "$MONITOR_FLAG" -eq 0 ]; then
            read -rp "    Continue monitor mode anyway, or switch to scheduled mode? [m/s]: " choice
            if [ "$choice" = "s" ] || [ "$choice" = "S" ]; then
                MONITOR_ACTIVE=0
                set_default_windows
                NUM_WINDOWS=${#WIN_STARTS[@]}
                [ -z "$OUTPUT_OVERRIDE" ] && OUT_DIR="$DEFAULT_OUTPUT_DIR"
                mkdir -p "$OUT_DIR"
                echo ""
                echo -e "  ${B}Recording windows:${NC}"
                for (( w=0; w<NUM_WINDOWS; w++ )); do
                    echo -e "    ${G}▸${NC} ${WIN_LABELS[$w]}"
                done
                echo -e "  ${B}Save to${NC}    ${OUT_DIR}/"
                echo -e "  ${B}Captions${NC}   .srt per segment (if available)"
                echo ""
                return 42
            fi
        fi
    else
        echo -e "    ${G}✓${NC} Captions detected via ${MONITOR_CC_METHOD} — monitor is GO"
    fi

    monitor_log "MONITOR START — ${keyword_count} keywords loaded"
    monitor_log "CC METHOD: ${MONITOR_CC_METHOD}"
    monitor_log "STREAM: ${MONITOR_STREAM_SUMMARY}"

    while true; do
        if [ -n "$MONITOR_UNTIL_SEC" ] && [ "$(now_seconds_of_day)" -ge "$MONITOR_UNTIL_SEC" ]; then
            monitor_log "MONITOR STOP — reached --until ${MONITOR_UNTIL_RAW}"
            break
        fi

        MONITOR_LAST_SEGMENT_RECORDED=$((MONITOR_LAST_SEGMENT_RECORDED + 1))
        monitor_record_segment "$MONITOR_LAST_SEGMENT_RECORDED" || {
            monitor_render_status
            continue
        }

        check_seg=$((MONITOR_LAST_SEGMENT_RECORDED - MONITOR_BUFFER_DEPTH - 1))
        if [ "$check_seg" -ge 1 ] && [ -n "${MONITOR_SEG_MP4[$check_seg]:-}" ]; then
            if [ -n "${MONITOR_FLAGGED_SEGMENTS[$check_seg]:-}" ]; then
                monitor_promote_segment "$check_seg"
            else
                monitor_cleanup_buffer_segment "$check_seg" "buffer expired, not flagged"
            fi
        fi

        if [ $((MONITOR_LAST_SEGMENT_RECORDED % 10)) -eq 0 ]; then
            monitor_disk_guard
        fi

        monitor_finalize_ready_matches "$MONITOR_LAST_SEGMENT_RECORDED" 0
        monitor_render_status
    done

    monitor_finalize_flagged_segments
    monitor_finalize_ready_matches "$((MONITOR_LAST_SEGMENT_RECORDED + MONITOR_BUFFER_DEPTH + 1))" 1
    monitor_print_summary
    open_output_dir "$OUT_DIR"
    return 0
}

POSITIONAL_URL=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        -q|--quiet)
            QUIET=1
            ;;
        --stream)
            [ "$#" -ge 2 ] || { echo -e "${R}✗ Missing value for --stream${NC}"; exit 1; }
            [ -z "$STREAM_SELECTOR" ] || { echo -e "${R}✗ Only one --stream value may be provided${NC}"; exit 1; }
            STREAM_SELECTOR="$2"
            shift
            ;;
        --stream=*)
            [ -z "$STREAM_SELECTOR" ] || { echo -e "${R}✗ Only one --stream value may be provided${NC}"; exit 1; }
            STREAM_SELECTOR="${1#*=}"
            ;;
        --test-streams)
            STREAM_TEST_FLAG=1
            ;;
        --update-channels)
            UPDATE_CHANNELS_FLAG=1
            ;;
        --mode)
            [ "$#" -ge 2 ] || { echo -e "${R}✗ Missing value for --mode${NC}"; exit 1; }
            [ -z "$MODE_OVERRIDE" ] || { echo -e "${R}✗ Only one --mode value may be provided${NC}"; exit 1; }
            MODE_OVERRIDE="$2"
            shift
            ;;
        --mode=*)
            [ -z "$MODE_OVERRIDE" ] || { echo -e "${R}✗ Only one --mode value may be provided${NC}"; exit 1; }
            MODE_OVERRIDE="${1#*=}"
            ;;
        --monitor)
            MONITOR_FLAG=1
            ;;
        --keywords)
            [ "$#" -ge 2 ] || { echo -e "${R}✗ Missing value for --keywords${NC}"; exit 1; }
            MONITOR_KEYWORDS_FILE="$2"
            shift
            ;;
        --keywords=*)
            MONITOR_KEYWORDS_FILE="${1#*=}"
            ;;
        --until)
            [ "$#" -ge 2 ] || { echo -e "${R}✗ Missing value for --until${NC}"; exit 1; }
            MONITOR_UNTIL_RAW="$2"
            shift
            ;;
        --until=*)
            MONITOR_UNTIL_RAW="${1#*=}"
            ;;
        --segment-length)
            [ "$#" -ge 2 ] || { echo -e "${R}✗ Missing value for --segment-length${NC}"; exit 1; }
            MONITOR_SEGMENT_SEC="$2"
            shift
            ;;
        --segment-length=*)
            MONITOR_SEGMENT_SEC="${1#*=}"
            ;;
        --url)
            [ "$#" -ge 2 ] || { echo -e "${R}✗ Missing value for --url${NC}"; exit 1; }
            [ -z "$MASTER_URL" ] || { echo -e "${R}✗ Only one URL may be provided${NC}"; exit 1; }
            MASTER_URL="$2"
            shift
            ;;
        --url=*)
            [ -z "$MASTER_URL" ] || { echo -e "${R}✗ Only one URL may be provided${NC}"; exit 1; }
            MASTER_URL="${1#*=}"
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo -e "${R}✗ Missing value for --output${NC}"; exit 1; }
            OUTPUT_OVERRIDE="$2"
            shift
            ;;
        --output=*)
            OUTPUT_OVERRIDE="${1#*=}"
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo -e "${R}✗ Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
        *)
            [ -z "$POSITIONAL_URL" ] || { echo -e "${R}✗ Only one URL may be provided${NC}"; exit 1; }
            POSITIONAL_URL="$1"
            ;;
    esac
    shift
done

while [ "$#" -gt 0 ]; do
    [ -z "$POSITIONAL_URL" ] || { echo -e "${R}✗ Only one URL may be provided${NC}"; exit 1; }
    POSITIONAL_URL="$1"
    shift
done

[ -z "$MASTER_URL" ] || [ -z "$POSITIONAL_URL" ] || { echo -e "${R}✗ Only one URL may be provided${NC}"; exit 1; }
MASTER_URL="${MASTER_URL:-$POSITIONAL_URL}"
OUT_DIR="${OUTPUT_OVERRIDE:-$DEFAULT_OUTPUT_DIR}"

if [ -n "$STREAM_SELECTOR" ] && [ -n "$MASTER_URL" ]; then
    echo -e "${R}✗ Use either --stream or a direct URL, not both${NC}"
    exit 1
fi

if [ "$MONITOR_FLAG" -eq 1 ]; then
    if [ -n "$MODE_OVERRIDE" ]; then
        MODE_OVERRIDE_NORMALIZED=$(normalize_mode_selector "$MODE_OVERRIDE" 2>/dev/null || true)
        if [ "$MODE_OVERRIDE_NORMALIZED" != "4" ]; then
            echo -e "${R}✗ --monitor cannot be combined with a different --mode${NC}"
            exit 1
        fi
    fi
    MODE_OVERRIDE="4"
fi

if [ -n "$MODE_OVERRIDE" ]; then
    RAW_MODE_OVERRIDE="$MODE_OVERRIDE"
    if ! MODE_OVERRIDE="$(normalize_mode_selector "$MODE_OVERRIDE")"; then
        echo -e "${R}✗ Invalid --mode value: ${RAW_MODE_OVERRIDE}${NC}"
        exit 1
    fi
    [ "$MODE_OVERRIDE" = "4" ] && MONITOR_FLAG=1
fi

if ! [[ "$MONITOR_SEGMENT_SEC" =~ ^[0-9]+$ ]] || [ "$MONITOR_SEGMENT_SEC" -lt 30 ] || [ "$MONITOR_SEGMENT_SEC" -gt 3600 ]; then
    echo -e "${R}✗ --segment-length must be between 30 and 3600 seconds${NC}"
    exit 1
fi
if [ -n "$MONITOR_UNTIL_RAW" ]; then
    if ! MONITOR_UNTIL_SEC=$(parse_time "$MONITOR_UNTIL_RAW"); then
        echo -e "${R}✗ Invalid --until time${NC}"
        exit 1
    fi
fi

if [ "$UPDATE_CHANNELS_FLAG" -eq 1 ]; then
    echo "Coming soon - for now, edit channels.conf manually"
    exit 0
fi

if [ "$STREAM_TEST_FLAG" -eq 1 ]; then
    test_all_streams
    exit 0
fi

initialize_stream_selection

if [ "$STREAM_SELECTION_VALIDATED" -eq 0 ]; then
    validate_selected_stream 0 || exit 1
fi

# ══════════════════════════════════════════════════════════
# MODE SELECTION
# ══════════════════════════════════════════════════════════
print_banner
echo ""
echo -e "  ${B}Stream${NC}     ${SELECTED_NAME}"
if [ -n "$SELECTED_SHORT" ] && [ "$SELECTED_SHORT" != "manual" ]; then
    echo -e "  ${B}Short${NC}      ${SELECTED_SHORT}"
fi
echo -e "  ${B}Master${NC}     $MASTER_URL"
if [ -n "$SELECTED_PROBE_SUMMARY" ]; then
    echo -e "  ${B}Probe${NC}      ${SELECTED_PROBE_SUMMARY}"
fi
if [ -n "$SELECTED_NOTES" ]; then
    echo -e "  ${B}Notes${NC}      ${SELECTED_NOTES}"
fi
echo ""
echo -e "  ${B}Choose recording mode:${NC}"
echo ""
echo -e "    ${W}1)${NC}  Scheduled — 5:55p→7:00p  then  9:55p→11:00p"
echo -e "    ${W}2)${NC}  Record now — enter a custom duration"
echo -e "    ${W}3)${NC}  Record now — enter start & end times"
echo -e "    ${W}4)${NC}  ⚡ Keyword monitor ${Y}(experimental)${NC} — record on keyword detection"
echo ""
if [ -n "$MODE_OVERRIDE" ]; then
    MODE_CHOICE="$MODE_OVERRIDE"
    if [ "$MODE_CHOICE" = "4" ]; then
        echo -e "  ${D}Mode selected via CLI override${NC}"
    else
        echo -e "  ${D}Mode ${MODE_CHOICE} selected via CLI override${NC}"
    fi
else
    read -rp "  Select [1/2/3/4]: " MODE_CHOICE
fi
echo ""

# Build the list of recording windows based on mode
declare -a WIN_STARTS=()   # start times in seconds-since-midnight
declare -a WIN_ENDS=()     # end times in seconds-since-midnight
declare -a WIN_LABELS=()   # display labels

case "$MODE_CHOICE" in
    4)
        [ -z "$OUTPUT_OVERRIDE" ] && OUT_DIR="$DEFAULT_MONITOR_OUTPUT_DIR"
        ;;
    2)
        read -rp "  How many minutes to record? " CUSTOM_MINS
        if ! [[ "$CUSTOM_MINS" =~ ^[0-9]+$ ]]; then
            echo -e "  ${R}✗ Duration must be a whole number of minutes${NC}"; exit 1
        fi
        if [ "$CUSTOM_MINS" -lt 1 ] || [ "$CUSTOM_MINS" -gt "$MAX_DURATION_MIN" ]; then
            echo -e "  ${R}✗ Duration must be between 1 and ${MAX_DURATION_MIN} minutes${NC}"; exit 1
        fi
        NOW_SEC=$(now_seconds_of_day)
        NOW_SEC=$((NOW_SEC - (NOW_SEC % 60)))
        END_SEC=$((NOW_SEC + CUSTOM_MINS*60))
        if [ "$END_SEC" -gt 86400 ]; then
            echo -e "  ${R}✗ Record-now duration cannot cross midnight${NC}"; exit 1
        fi
        WIN_STARTS+=("$NOW_SEC")
        WIN_ENDS+=("$END_SEC")
        WIN_LABELS+=("Now → +${CUSTOM_MINS}min")
        ;;
    3)
        echo -e "  Enter times in 24h format (e.g. 14:30) or 12h (e.g. 2:30pm)"
        echo ""
        read -rp "  Start time: " RAW_START
        read -rp "  End time:   " RAW_END
        if ! S=$(parse_time "$RAW_START"); then
            echo -e "  ${R}✗ Invalid start time${NC}"; exit 1
        fi
        if ! E=$(parse_time "$RAW_END"); then
            echo -e "  ${R}✗ Invalid end time${NC}"; exit 1
        fi
        if [ "$E" -le "$S" ]; then
            echo -e "  ${R}✗ End time must be after start time${NC}"; exit 1
        fi
        SH=$((S/3600)); SM=$(( (S%3600)/60 ))
        EH=$((E/3600)); EM=$(( (E%3600)/60 ))
        WIN_STARTS+=("$S")
        WIN_ENDS+=("$E")
        WIN_LABELS+=("$(printf '%02d:%02d → %02d:%02d' "$SH" "$SM" "$EH" "$EM")")
        ;;
    *)
        # Default: scheduled windows
        set_default_windows
        ;;
esac

NUM_WINDOWS=${#WIN_STARTS[@]}

if [ "$MODE_CHOICE" != "4" ]; then
    echo -e "  ${B}Recording windows:${NC}"
    for (( w=0; w<NUM_WINDOWS; w++ )); do
        echo -e "    ${G}▸${NC} ${WIN_LABELS[$w]}"
    done
fi
echo -e "  ${B}Save to${NC}    ${OUT_DIR}/"
echo -e "  ${B}Captions${NC}   .srt per segment (if available)"
echo ""

# ── Preflight ──
if ! command -v ffmpeg &>/dev/null; then
    echo -e "${R}✗ ffmpeg not found! → brew install ffmpeg${NC}"; exit 1
fi
echo -e "${G}✓${NC} ffmpeg"
if ! command -v ffprobe &>/dev/null; then
    echo -e "${R}✗ ffprobe not found! → brew install ffmpeg${NC}"; exit 1
fi
echo -e "${G}✓${NC} ffprobe"
if ! command -v curl &>/dev/null; then
    echo -e "${R}✗ curl not found!${NC}"; exit 1
fi
echo -e "${G}✓${NC} curl"
if ! command -v python3 &>/dev/null; then
    echo -e "${R}✗ python3 not found!${NC}"; exit 1
fi
echo -e "${G}✓${NC} python3"

mkdir -p "$OUT_DIR"
echo -e "${G}✓${NC} Output dir ready"
echo ""

# ══════════════════════════════════════════════════════════
# PARSE MASTER PLAYLIST → FIND BEST VARIANT
# ══════════════════════════════════════════════════════════
echo -e "${B}─── Parsing Master Playlist ────────────────────────────────${NC}"
echo -e "  ${D}Fetching ${MASTER_URL}${NC}"

MASTER_CONTENT=$(curl -fsSL -A "$ACTIVE_HTTP_USER_AGENT" "$MASTER_URL" 2>/dev/null)
if [ -z "$MASTER_CONTENT" ]; then
    echo -e "  ${R}✗ Failed to fetch master playlist${NC}"
    exit 1
fi

# Extract base URL for resolving relative paths
BASE_URL=$(echo "$MASTER_URL" | sed 's|/[^/]*$|/|')

# Use python to parse m3u8 and find the highest bandwidth variant
STREAM_URL=$(echo "$MASTER_CONTENT" | python3 -c "
import sys

lines = sys.stdin.read().strip().split('\n')
base_url = '$BASE_URL'
variants = []
i = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith('#EXT-X-STREAM-INF:'):
        attrs = line.split(':', 1)[1]
        bw = 0
        res = ''
        codecs = ''
        for part in attrs.split(','):
            part = part.strip()
            if part.startswith('BANDWIDTH='):
                bw = int(part.split('=')[1])
            elif part.startswith('RESOLUTION='):
                res = part.split('=')[1]
            elif part.startswith('CODECS='):
                codecs = part.split('=', 1)[1].strip('\"')
        # Next non-comment line is the URL
        j = i + 1
        while j < len(lines) and lines[j].strip().startswith('#'):
            j += 1
        if j < len(lines):
            url = lines[j].strip()
            if not url.startswith('http'):
                url = base_url + url
            variants.append((bw, res, codecs, url))
        i = j + 1
    else:
        i += 1

if not variants:
    print('ERROR:No variants found in playlist')
    sys.exit(1)

# Sort by bandwidth descending
variants.sort(key=lambda x: x[0], reverse=True)

# Print all variants for display
for bw, res, codecs, url in variants:
    mbps = bw / 1_000_000
    print(f'VARIANT:{mbps:.1f} Mbps|{res}|{codecs}|{url}')

# Print best
best = variants[0]
print(f'BEST:{best[3]}')
")

if echo "$STREAM_URL" | grep -q "^ERROR:"; then
    echo -e "  ${R}✗ ${STREAM_URL#ERROR:}${NC}"
    exit 1
fi

# Display all variants
echo ""
echo -e "  ${B}Available variants:${NC}"
VARIANT_NUM=0
echo "$STREAM_URL" | grep "^VARIANT:" | while IFS='|' read -r info res codecs url; do
    VARIANT_NUM=$((VARIANT_NUM + 1))
    mbps="${info#VARIANT:}"
    if [ "$VARIANT_NUM" -eq 1 ]; then
        echo -e "    ${G}★ ${W}${mbps}  ${res}  ${codecs}${NC}  ${G}← SELECTED${NC}"
    else
        echo -e "    ${D}  ${mbps}  ${res}  ${codecs}${NC}"
    fi
done

# Get the best URL
BEST_URL=$(echo "$STREAM_URL" | grep "^BEST:" | head -1 | sed 's/^BEST://')

if [ -z "$BEST_URL" ]; then
    echo -e "  ${R}✗ Could not determine best stream URL${NC}"
    exit 1
fi

echo ""
echo -e "  ${G}✓${NC} Selected highest bandwidth variant"
echo -e "  ${D}${BEST_URL:0:80}...${NC}"
echo -e "${B}────────────────────────────────────────────────────────────${NC}"
echo ""

# ── Probe the selected variant ──
echo -e "${B}─── Stream Details (best variant) ──────────────────────────${NC}"
PROBE_JSON=$(ffprobe -user_agent "$ACTIVE_HTTP_USER_AGENT" -v quiet -print_format json -show_format -show_streams -i "$BEST_URL" 2>/dev/null)
if [ -n "$PROBE_JSON" ]; then
    echo "$PROBE_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    streams = d.get('streams', [])
    fmt = d.get('format', {})
    vid = [s for s in streams if s.get('codec_type') == 'video']
    aud = [s for s in streams if s.get('codec_type') == 'audio']
    sub = [s for s in streams if s.get('codec_type') == 'subtitle']
    print(f'  Format       {fmt.get(\"format_long_name\", \"unknown\")}')
    if vid:
        v = vid[0]
        w = v.get('width', '?'); h = v.get('height', '?')
        codec = v.get('codec_name', '?')
        fps = v.get('r_frame_rate', '?')
        prof = v.get('profile', '?')
        level = v.get('level', '?')
        pix = v.get('pix_fmt', '?')
        cs = v.get('color_space', '?')
        ct = v.get('color_transfer', '?')
        cp = v.get('color_primaries', '?')
        br = v.get('bit_rate')
        brs = f'{int(br)//1000} kbps' if br else 'N/A'
        tbr = fmt.get('bit_rate')
        tbrs = f'{int(tbr)//1000} kbps' if tbr else ''
        print(f'  Video        {codec} ({prof} L{level})')
        print(f'  Resolution   {w}x{h}')
        print(f'  FPS          {fps}')
        print(f'  Pixel Fmt    {pix}')
        print(f'  Color        {cs} / {ct} / {cp}')
        print(f'  Bitrate      vid={brs}  total={tbrs}')
    if aud:
        a = aud[0]
        abr = a.get('bit_rate')
        abrs = f'{int(abr)//1000} kbps' if abr else 'N/A'
        print(f'  Audio        {a.get(\"codec_name\",\"?\")} {a.get(\"profile\",\"\")}  {a.get(\"sample_rate\",\"?\")} Hz  {a.get(\"channels\",\"?\")}ch  {abrs}')
    if sub:
        for s in sub:
            print(f'  Subtitle     {s.get(\"codec_name\",\"?\")}  lang={s.get(\"tags\",{}).get(\"language\",\"?\")}')
    else:
        print(f'  Subtitle     none (will try embedded)')
except Exception as e:
    print(f'  Parse error: {e}')
" 2>/dev/null || echo -e "  ${Y}Could not parse${NC}"
else
    echo -e "  ${Y}Probe returned empty${NC}"
fi
echo -e "${B}────────────────────────────────────────────────────────────${NC}"
echo ""

if [ "$MODE_CHOICE" = "4" ]; then
    run_keyword_monitor
    MONITOR_RC=$?
    if [ "$MONITOR_RC" -eq 42 ]; then
        MODE_CHOICE=1
    else
        exit "$MONITOR_RC"
    fi
fi

# ══════════════════════════════════════════════════════════
# PHASE 1: TEST (using best variant URL)
# ══════════════════════════════════════════════════════════
echo -e "${BG_C} PHASE 1 ${NC}  ${B}Quality Test (${TEST_SEC}s)${NC}"
echo ""
if [ "$QUIET" -eq 1 ]; then
    echo -e "  ${D}Running quality test capture...${NC}"
fi

TEST_FILE="${OUT_DIR}/_test.mp4"
TLOG=$(make_temp_file fftest)
track_temp_file "$TEST_FILE"
track_temp_file "$TLOG"

ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$BEST_URL" -t "$TEST_SEC" \
    -c copy -movflags +faststart \
    -loglevel warning -stats \
    "$TEST_FILE" 2>"$TLOG" &
TPID=$!
track_pid "$TPID"
SI=0; TS=$(date +%s)

while kill -0 "$TPID" 2>/dev/null; do
    if [ "$QUIET" -eq 0 ]; then
        E=$(( $(date +%s) - TS ))
        R=$((TEST_SEC - E)); [ "$R" -lt 0 ] && R=0
        PCT=$((E * 100 / TEST_SEC)); [ "$PCT" -gt 100 ] && PCT=100
        if TEST_BYTES=$(file_size_bytes "$TEST_FILE" 2>/dev/null); then
            SZ=$(human_size "$TEST_BYTES")
        else
            SZ="..."
        fi
        BAR=$(draw_bar "$PCT" 25)
        printf "\r  ${G}${SPIN[$SI]}${NC} TEST [${G}${BAR}${NC}] %3d%%  ${C}%02ds${NC}/${TEST_SEC}s  ${B}%s${NC}   " "$PCT" "$E" "$SZ"
        SI=$(( (SI+1) % 10 ))
    fi
    sleep 1
done

wait "$TPID"; TEC=$?
forget_pid "$TPID"
rm -f "$TLOG"
forget_temp_file "$TLOG"
[ "$QUIET" -eq 0 ] && echo ""

if [ "$TEC" -eq 0 ] && [ -f "$TEST_FILE" ]; then
    TB=$(wc -c < "$TEST_FILE" | tr -d ' ')
    if [ "$TB" -gt 1024 ]; then
        RATE=$(( TB / TEST_SEC / 1024 ))

        # Verify resolution of test file
        TEST_RES=$(ffprobe -v quiet -select_streams v:0 \
            -show_entries stream=width,height,codec_name,profile \
            -of csv=p=0 "$TEST_FILE" 2>/dev/null)
        echo -e "  ${G}${B}✓ TEST PASSED${NC}"
        echo -e "    Size:       $(human_size "$TB")  (~${RATE} KB/s)"
        echo -e "    Confirmed:  ${W}${TEST_RES}${NC}"

        # Quick validation
        TEST_W=$(echo "$TEST_RES" | cut -d',' -f2 2>/dev/null)
        if [ -n "$TEST_W" ] && [ "$TEST_W" -ge 1920 ] 2>/dev/null; then
            echo -e "    ${G}★ 1080p confirmed!${NC}"
        elif [ -n "$TEST_W" ] && [ "$TEST_W" -ge 1280 ] 2>/dev/null; then
            echo -e "    ${Y}⚠ Got 720p — 1080p variant may have switched down${NC}"
        elif [ -n "$TEST_W" ] && [ "$TEST_W" -lt 1280 ] 2>/dev/null; then
            echo -e "    ${R}⚠ Resolution lower than expected (${TEST_W}px wide)${NC}"
        fi

        rm -f "$TEST_FILE"
        forget_temp_file "$TEST_FILE"
    else
        echo -e "  ${R}${B}✗ TEST FAILED${NC} — file too small (${TB} bytes)"
        rm -f "$TEST_FILE"
        forget_temp_file "$TEST_FILE"
        exit 1
    fi
else
    echo -e "  ${R}${B}✗ TEST FAILED${NC} — ffmpeg exit code $TEC"
    rm -f "$TEST_FILE"
    forget_temp_file "$TEST_FILE"
    exit 1
fi

echo ""

# ══════════════════════════════════════════════════════════
# FUNCTION: Record one window
# ══════════════════════════════════════════════════════════
GLOBAL_SEG_NUM=0    # running segment counter across all windows
GRAND_TOTAL_SIZE=0
GRAND_SEG_OK=0
GRAND_SEG_FAIL=0
GRAND_CC_FILES=0
GRAND_START=$(date +%s)

record_window() {
    local WIN_NUM=$1
    local WIN_START_SEC=$2
    local WIN_END_SEC=$3
    local WIN_LABEL=$4

    local TOTAL_SEC=$(( WIN_END_SEC - WIN_START_SEC ))
    local NUM_SEGMENTS=$((TOTAL_SEC / SEGMENT_SEC))
    [ $((TOTAL_SEC % SEGMENT_SEC)) -gt 0 ] && NUM_SEGMENTS=$((NUM_SEGMENTS + 1))

    local SH=$((WIN_START_SEC/3600)); local SM=$(( (WIN_START_SEC%3600)/60 ))
    local EH=$((WIN_END_SEC/3600));   local EM=$(( (WIN_END_SEC%3600)/60 ))

    echo -e "${C}${B}══════════════════════════════════════════════════════════${NC}"
    echo -e "${C}${B}  Window ${WIN_NUM}: ${WIN_LABEL}${NC}"
    echo -e "${C}${B}══════════════════════════════════════════════════════════${NC}"
    echo ""

    # ── Wait for this window's start ──
    WAIT_LOGGED=0
    while true; do
        NOW=$(now_seconds_of_day)
        [ "$NOW" -ge "$WIN_START_SEC" ] && break
        W=$((WIN_START_SEC - NOW))
        if [ "$QUIET" -eq 0 ]; then
            printf "\r  ${Y}⏳ Recording at %02d:%02d — %02d:%02d remaining ...${NC}   " \
                "$SH" "$SM" $((W/60)) $((W%60))
        elif [ "$WAIT_LOGGED" -eq 0 ]; then
            echo -e "  ${D}Waiting for recording window at $(printf '%02d:%02d' "$SH" "$SM")${NC}"
            WAIT_LOGGED=1
        fi
        sleep 1
    done
    [ "$QUIET" -eq 0 ] && echo ""

    echo -e "${BG_G} RECORD ${NC}  ${B}${NUM_SEGMENTS} × $(( SEGMENT_SEC/60 ))min segments  [1080p]${NC}"
    echo ""

    local TOTAL_SIZE=0; local SEG_OK=0; local SEG_FAIL=0; local CC_FILES=0

    for (( i=1; i<=NUM_SEGMENTS; i++ )); do
        GLOBAL_SEG_NUM=$((GLOBAL_SEG_NUM + 1))

        # For the last segment, cap duration to not overshoot the window
        local REMAINING_SEC
        NOW=$(now_seconds_of_day)
        REMAINING_SEC=$((WIN_END_SEC - NOW))
        local THIS_SEG_SEC=$SEGMENT_SEC
        if [ "$REMAINING_SEC" -lt "$SEGMENT_SEC" ] && [ "$REMAINING_SEC" -gt 0 ]; then
            THIS_SEG_SEC=$REMAINING_SEC
        fi
        if [ "$REMAINING_SEC" -le 0 ]; then
            echo -e "  ${Y}Window ended, skipping remaining segments${NC}"
            break
        fi

        SEG_FILE="${OUT_DIR}/segment_$(printf '%03d' "$GLOBAL_SEG_NUM").mp4"
        SRT_FILE="${OUT_DIR}/segment_$(printf '%03d' "$GLOBAL_SEG_NUM").srt"
        SEG_CLOCK=$(date +%H:%M:%S)

        echo -e "  ${BG_C} SEG $i/$NUM_SEGMENTS ${NC}  ${SEG_CLOCK}  →  segment_$(printf '%03d' "$GLOBAL_SEG_NUM").mp4  (${THIS_SEG_SEC}s)"

        ATTEMPT=1
        VEC=1
        while [ "$ATTEMPT" -le 2 ]; do
            [ "$ATTEMPT" -gt 1 ] && echo -e "    ${Y}↻ Retry ${ATTEMPT}/2 in 5s after segment failure${NC}"
            [ "$ATTEMPT" -gt 1 ] && sleep 5
            [ "$ATTEMPT" -gt 1 ] && rm -f "$SEG_FILE" "$SRT_FILE"

            SEG_TS=$(date +%s)
            SLOG=$(make_temp_file ffseg)
            track_temp_file "$SLOG"

            # Main video
            ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$BEST_URL" -t "$THIS_SEG_SEC" \
                -c:v copy -c:a copy \
                -movflags +faststart -loglevel warning -stats \
                "$SEG_FILE" 2>"$SLOG" &
            VID_PID=$!
            track_pid "$VID_PID"
            STALL_MARKER=$(make_temp_file ffstall)
            track_temp_file "$STALL_MARKER"
            WATCHDOG_PID=$(start_timeout_watchdog "$VID_PID" "$((THIS_SEG_SEC * SEGMENT_TIMEOUT_MULTIPLIER))" "$STALL_MARKER")
            track_pid "$WATCHDOG_PID"

            # CC extraction
            CCLOG=$(make_temp_file ffcc)
            track_temp_file "$CCLOG"
            ffmpeg -y -user_agent "$ACTIVE_HTTP_USER_AGENT" -i "$MASTER_URL" -t "$THIS_SEG_SEC" \
                -map 0:s:0? -c:s srt -loglevel error \
                "$SRT_FILE" 2>"$CCLOG" &
            CC_PID=$!
            track_pid "$CC_PID"

            SI=0
            while kill -0 "$VID_PID" 2>/dev/null; do
                if [ "$QUIET" -eq 0 ]; then
                    E=$(( $(date +%s) - SEG_TS ))
                    R=$((THIS_SEG_SEC - E)); [ "$R" -lt 0 ] && R=0
                    PCT=$((E * 100 / THIS_SEG_SEC)); [ "$PCT" -gt 100 ] && PCT=100

                    GPCT=$(( ((i-1)*SEGMENT_SEC + E) * 100 / TOTAL_SEC ))
                    [ "$GPCT" -gt 100 ] && GPCT=100

                    if SEG_BYTES=$(file_size_bytes "$SEG_FILE" 2>/dev/null); then
                        SZ=$(human_size "$SEG_BYTES")
                    else
                        SZ="..."
                    fi

                    BAR=$(draw_bar "$PCT" 25)
                    GBAR=$(draw_bar "$GPCT" 20)

                    printf "\r  ${G}${SPIN[$SI]}${NC} seg [${G}${BAR}${NC}] %3d%%  ${C}%d:%02d${NC}  ${B}%s${NC}  │  win [${Y}${GBAR}${NC}] %3d%%  " \
                        "$PCT" "$((E/60))" "$((E%60))" "$SZ" "$GPCT"
                    SI=$(( (SI+1) % 10 ))
                fi
                sleep 1
            done

            wait "$VID_PID"; VEC=$?
            forget_pid "$VID_PID"
            ATTEMPT_ELAPSED=$(( $(date +%s) - SEG_TS ))
            stop_timeout_watchdog "$WATCHDOG_PID"

            # Kill CC if stuck
            ( sleep 8; kill "$CC_PID" 2>/dev/null ) &
            KP=$!; wait "$CC_PID" 2>/dev/null
            forget_pid "$CC_PID"
            kill "$KP" 2>/dev/null; wait "$KP" 2>/dev/null

            rm -f "$SLOG" "$CCLOG"
            forget_temp_file "$SLOG"
            forget_temp_file "$CCLOG"
            if [ -s "$STALL_MARKER" ]; then
                echo -e "    ${Y}⚠ Segment stalled and hit the ${SEGMENT_TIMEOUT_MULTIPLIER}x timeout (${THIS_SEG_SEC}s → $((THIS_SEG_SEC * SEGMENT_TIMEOUT_MULTIPLIER))s)${NC}"
            elif [ "$ATTEMPT_ELAPSED" -gt $((THIS_SEG_SEC + SLOW_SEGMENT_GRACE_SEC)) ]; then
                echo -e "    ${Y}⚠ Segment ran ${ATTEMPT_ELAPSED}s for a ${THIS_SEG_SEC}s target${NC}"
            fi
            rm -f "$STALL_MARKER"
            forget_temp_file "$STALL_MARKER"
            [ "$QUIET" -eq 0 ] && echo ""

            if [ "$VEC" -eq 0 ] && [ -f "$SEG_FILE" ]; then
                break
            fi

            ATTEMPT=$((ATTEMPT + 1))
        done

        # Video result + resolution verification
        if [ "$VEC" -eq 0 ] && [ -f "$SEG_FILE" ]; then
            SB=$(wc -c < "$SEG_FILE" | tr -d ' ')
            TOTAL_SIZE=$((TOTAL_SIZE + SB))
            SEG_OK=$((SEG_OK + 1))
            SEG_RES=$(ffprobe -user_agent "$ACTIVE_HTTP_USER_AGENT" -v quiet -select_streams v:0 \
                -show_entries stream=width,height -of csv=p=0 "$SEG_FILE" 2>/dev/null)
            echo -e "    ${G}✓${NC} Video  $(human_size "$SB")  ${D}[${SEG_RES}]${NC}"
        else
            SEG_FAIL=$((SEG_FAIL + 1))
            echo -e "    ${R}✗${NC} Video failed (exit $VEC)"
        fi

        # CC result
        if [ -f "$SRT_FILE" ]; then
            CB=$(wc -c < "$SRT_FILE" | tr -d ' ')
            if [ "$CB" -gt 10 ]; then
                CC_FILES=$((CC_FILES + 1))
                echo -e "    ${G}✓${NC} Captions  $(human_size "$CB")"
            else
                rm -f "$SRT_FILE"
                echo -e "    ${D}─ No captions this segment${NC}"
            fi
        else
            echo -e "    ${D}─ No captions this segment${NC}"
        fi
        echo ""
    done

    # Update grand totals
    GRAND_TOTAL_SIZE=$((GRAND_TOTAL_SIZE + TOTAL_SIZE))
    GRAND_SEG_OK=$((GRAND_SEG_OK + SEG_OK))
    GRAND_SEG_FAIL=$((GRAND_SEG_FAIL + SEG_FAIL))
    GRAND_CC_FILES=$((GRAND_CC_FILES + CC_FILES))

    echo -e "  ${G}✓ Window ${WIN_NUM} complete${NC} — ${SEG_OK} segments, $(human_size "$TOTAL_SIZE")"
    echo ""
}

# ══════════════════════════════════════════════════════════
# RECORD ALL WINDOWS
# ══════════════════════════════════════════════════════════
for (( w=0; w<NUM_WINDOWS; w++ )); do
    record_window $((w+1)) "${WIN_STARTS[$w]}" "${WIN_ENDS[$w]}" "${WIN_LABELS[$w]}"
done

# ══════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════
ELAPSED_TOTAL=$(( $(date +%s) - GRAND_START ))

echo -e "${C}${B}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${C}${B}║  Recording Complete — $(date +%H:%M:%S)                            ║${NC}"
echo -e "${C}${B}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${B}Stream${NC}      ${SELECTED_NAME}"
echo -e "  ${B}Quality${NC}     1080p (highest variant)"
echo -e "  ${B}Windows${NC}     ${NUM_WINDOWS}"
echo -e "  ${B}Segments${NC}    ${G}${GRAND_SEG_OK} ok${NC}  ${R}${GRAND_SEG_FAIL} failed${NC}  /  ${GLOBAL_SEG_NUM} total"
echo -e "  ${B}Total size${NC}  $(human_size "$GRAND_TOTAL_SIZE")"
echo -e "  ${B}Captions${NC}    ${GRAND_CC_FILES} .srt files"
echo -e "  ${B}Duration${NC}    $(( ELAPSED_TOTAL/60 ))m $(( ELAPSED_TOTAL%60 ))s"
echo -e "  ${B}Location${NC}    ${OUT_DIR}/"
echo ""
echo -e "  ${B}Files:${NC}"
ls -lh "$OUT_DIR"/ | tail -n +2 | while read line; do echo "    $line"; done
echo ""

open_output_dir "$OUT_DIR"
