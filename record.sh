#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# HLS Stream Recorder — MAX QUALITY
# 1) Parses master m3u8 to find highest bitrate variant
# 2) Runs a 15s test to verify stream + quality
# 3) Records 5-min segments across scheduled windows
#    or in a custom on-demand time range
# All files saved next to this script
# ─────────────────────────────────────────────────────────

MASTER_URL="${1:-https://example.com/stream/index.m3u8}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/recording_$(date +%Y%m%d)"

SEGMENT_SEC=300  # 5 minutes
TEST_SEC=15
MAX_DURATION_MIN=1440

declare -a TEMP_FILES=()
declare -a ACTIVE_PIDS=()
CLEANUP_DONE=0

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
    local pct=$1 w=${2:-30}
    local f=$((pct * w / 100)) e=$((w - f))
    printf '█%.0s' $(seq 1 $f 2>/dev/null)
    printf '░%.0s' $(seq 1 $e 2>/dev/null)
}

human_size() {
    echo "$1" | python3 -c "
b=int(open('/dev/stdin').read())
for u in ['B','KB','MB','GB']:
    if b<1024: print(f'{b:.1f} {u}'); break
    b/=1024
"
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

    for path in "${TEMP_FILES[@]}"; do
        rm -f "$path"
    done

    return "$exit_code"
}

trap 'cleanup $?' EXIT
trap 'cleanup 130; exit 130' INT
trap 'cleanup 143; exit 143' TERM

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

# ══════════════════════════════════════════════════════════
# MODE SELECTION
# ══════════════════════════════════════════════════════════
clear
echo -e "${C}${B}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${C}${B}║          📡  HLS Stream Recorder  —  MAX QUALITY         ║${NC}"
echo -e "${C}${B}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${B}Master${NC}     $MASTER_URL"
echo ""
echo -e "  ${B}Choose recording mode:${NC}"
echo ""
echo -e "    ${W}1)${NC}  Scheduled — 5:55p→7:00p  then  9:55p→11:00p"
echo -e "    ${W}2)${NC}  Record now — enter a custom duration"
echo -e "    ${W}3)${NC}  Record now — enter start & end times"
echo ""
read -rp "  Select [1/2/3]: " MODE_CHOICE
echo ""

# Build the list of recording windows based on mode
declare -a WIN_STARTS=()   # start times in seconds-since-midnight
declare -a WIN_ENDS=()     # end times in seconds-since-midnight
declare -a WIN_LABELS=()   # display labels

case "$MODE_CHOICE" in
    2)
        read -rp "  How many minutes to record? " CUSTOM_MINS
        if ! [[ "$CUSTOM_MINS" =~ ^[0-9]+$ ]]; then
            echo -e "  ${R}✗ Duration must be a whole number of minutes${NC}"; exit 1
        fi
        if [ "$CUSTOM_MINS" -lt 1 ] || [ "$CUSTOM_MINS" -gt "$MAX_DURATION_MIN" ]; then
            echo -e "  ${R}✗ Duration must be between 1 and ${MAX_DURATION_MIN} minutes${NC}"; exit 1
        fi
        NH=$(date +%H); NM=$(date +%M)
        NOW_SEC=$((10#$NH*3600 + 10#$NM*60))
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
        WIN_STARTS+=("$((WIN1_START_HOUR*3600 + WIN1_START_MIN*60))")
        WIN_ENDS+=("$((WIN1_END_HOUR*3600 + WIN1_END_MIN*60))")
        WIN_LABELS+=("$(printf '%02d:%02d → %02d:%02d' "$WIN1_START_HOUR" "$WIN1_START_MIN" "$WIN1_END_HOUR" "$WIN1_END_MIN")")

        WIN_STARTS+=("$((WIN2_START_HOUR*3600 + WIN2_START_MIN*60))")
        WIN_ENDS+=("$((WIN2_END_HOUR*3600 + WIN2_END_MIN*60))")
        WIN_LABELS+=("$(printf '%02d:%02d → %02d:%02d' "$WIN2_START_HOUR" "$WIN2_START_MIN" "$WIN2_END_HOUR" "$WIN2_END_MIN")")
        ;;
esac

NUM_WINDOWS=${#WIN_STARTS[@]}

echo -e "  ${B}Recording windows:${NC}"
for (( w=0; w<NUM_WINDOWS; w++ )); do
    echo -e "    ${G}▸${NC} ${WIN_LABELS[$w]}"
done
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

MASTER_CONTENT=$(curl -s "$MASTER_URL")
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
PROBE_JSON=$(ffprobe -v quiet -print_format json -show_format -show_streams -i "$BEST_URL" 2>/dev/null)
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

# ══════════════════════════════════════════════════════════
# PHASE 1: TEST (using best variant URL)
# ══════════════════════════════════════════════════════════
echo -e "${BG_C} PHASE 1 ${NC}  ${B}Quality Test (${TEST_SEC}s)${NC}"
echo ""

TEST_FILE="${OUT_DIR}/_test.mp4"
TLOG=$(mktemp /tmp/fftest.XXXXXX)
track_temp_file "$TEST_FILE"
track_temp_file "$TLOG"

ffmpeg -y -i "$BEST_URL" -t "$TEST_SEC" \
    -c copy -movflags +faststart \
    -loglevel warning -stats \
    "$TEST_FILE" 2>"$TLOG" &
TPID=$!
track_pid "$TPID"
SI=0; TS=$(date +%s)

while kill -0 "$TPID" 2>/dev/null; do
    E=$(( $(date +%s) - TS ))
    R=$((TEST_SEC - E)); [ "$R" -lt 0 ] && R=0
    PCT=$((E * 100 / TEST_SEC)); [ "$PCT" -gt 100 ] && PCT=100
    [ -f "$TEST_FILE" ] && SZ=$(du -sh "$TEST_FILE" 2>/dev/null | cut -f1) || SZ="..."
    BAR=$(draw_bar $PCT 25)
    printf "\r  ${G}${SPIN[$SI]}${NC} TEST [${G}${BAR}${NC}] %3d%%  ${C}%02ds${NC}/${TEST_SEC}s  ${B}%s${NC}   " "$PCT" "$E" "$SZ"
    SI=$(( (SI+1) % 10 )); sleep 1
done

wait "$TPID"; TEC=$?
forget_pid "$TPID"
rm -f "$TLOG"
forget_temp_file "$TLOG"
echo ""

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
    while true; do
        NH=$(date +%-H); NM=$(date +%-M); NS=$(date +%-S)
        NOW=$((NH*3600 + NM*60 + NS))
        [ "$NOW" -ge "$WIN_START_SEC" ] && break
        W=$((WIN_START_SEC - NOW))
        printf "\r  ${Y}⏳ Recording at %02d:%02d — %02d:%02d remaining ...${NC}   " \
            "$SH" "$SM" $((W/60)) $((W%60))
        sleep 1
    done
    echo ""

    echo -e "${BG_G} RECORD ${NC}  ${B}${NUM_SEGMENTS} × $(( SEGMENT_SEC/60 ))min segments  [1080p]${NC}"
    echo ""

    local TOTAL_SIZE=0; local SEG_OK=0; local SEG_FAIL=0; local CC_FILES=0

    for (( i=1; i<=NUM_SEGMENTS; i++ )); do
        GLOBAL_SEG_NUM=$((GLOBAL_SEG_NUM + 1))

        # For the last segment, cap duration to not overshoot the window
        local REMAINING_SEC
        NH=$(date +%-H); NM=$(date +%-M); NS=$(date +%-S)
        NOW=$((NH*3600 + NM*60 + NS))
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
            SLOG=$(mktemp /tmp/ffseg.XXXXXX)
            track_temp_file "$SLOG"

            # Main video
            ffmpeg -y -i "$BEST_URL" -t "$THIS_SEG_SEC" \
                -c:v copy -c:a copy \
                -movflags +faststart -loglevel warning -stats \
                "$SEG_FILE" 2>"$SLOG" &
            VID_PID=$!
            track_pid "$VID_PID"

            # CC extraction
            CCLOG=$(mktemp /tmp/ffcc.XXXXXX)
            track_temp_file "$CCLOG"
            ffmpeg -y -i "$MASTER_URL" -t "$THIS_SEG_SEC" \
                -map 0:s:0? -c:s srt -loglevel error \
                "$SRT_FILE" 2>"$CCLOG" &
            CC_PID=$!
            track_pid "$CC_PID"

            SI=0
            while kill -0 "$VID_PID" 2>/dev/null; do
                E=$(( $(date +%s) - SEG_TS ))
                R=$((THIS_SEG_SEC - E)); [ "$R" -lt 0 ] && R=0
                PCT=$((E * 100 / THIS_SEG_SEC)); [ "$PCT" -gt 100 ] && PCT=100

                GPCT=$(( ((i-1)*SEGMENT_SEC + E) * 100 / TOTAL_SEC ))
                [ "$GPCT" -gt 100 ] && GPCT=100

                [ -f "$SEG_FILE" ] && SZ=$(du -sh "$SEG_FILE" 2>/dev/null | cut -f1) || SZ="..."

                BAR=$(draw_bar $PCT 25)
                GBAR=$(draw_bar $GPCT 20)

                printf "\r  ${G}${SPIN[$SI]}${NC} seg [${G}${BAR}${NC}] %3d%%  ${C}%d:%02d${NC}  ${B}%s${NC}  │  win [${Y}${GBAR}${NC}] %3d%%  " \
                    "$PCT" "$((E/60))" "$((E%60))" "$SZ" "$GPCT"
                SI=$(( (SI+1) % 10 )); sleep 1
            done

            wait "$VID_PID"; VEC=$?
            forget_pid "$VID_PID"

            # Kill CC if stuck
            ( sleep 8; kill "$CC_PID" 2>/dev/null ) &
            KP=$!; wait "$CC_PID" 2>/dev/null
            forget_pid "$CC_PID"
            kill "$KP" 2>/dev/null; wait "$KP" 2>/dev/null

            rm -f "$SLOG" "$CCLOG"
            forget_temp_file "$SLOG"
            forget_temp_file "$CCLOG"
            echo ""

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
            SEG_RES=$(ffprobe -v quiet -select_streams v:0 \
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

if command -v open &>/dev/null; then
    open "$OUT_DIR"
    echo -e "  ${G}📂 Opened in Finder${NC}"
elif command -v xdg-open &>/dev/null; then
    xdg-open "$OUT_DIR" >/dev/null 2>&1 &
    echo -e "  ${G}📂 Opened output folder${NC}"
fi
