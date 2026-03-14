#!/usr/bin/env bash

set -u

MASTER_URL="${1:-https://example.com/stream/index.m3u8}"
HTTP_USER_AGENT="${HLS_RECORDER_USER_AGENT:-Mozilla/5.0 (HLS Stream Recorder Debug)}"
SEG_SEC="${SEG_SEC:-30}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/debug-cc.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

for cmd in curl ffmpeg ffprobe python3 sed grep wc head; do
    need_cmd "$cmd"
done

human_size() {
    echo "$1" | python3 -c "
b=int(open('/dev/stdin').read())
for unit in ['B', 'KB', 'MB', 'GB']:
    if b < 1024:
        print(f'{b:.1f} {unit}')
        break
    b /= 1024
"
}

summarize_output() {
    local label="$1"
    local file="$2"
    local log_file="$3"
    local line_count byte_count

    echo ""
    echo "=== ${label} ==="
    if [ -s "$file" ]; then
        byte_count=$(wc -c < "$file" | tr -d ' ')
        line_count=$(wc -l < "$file" | tr -d ' ')
        echo "Output: $file"
        echo "Size:   $(human_size "$byte_count") (${byte_count} bytes)"
        echo "Lines:  ${line_count}"
        echo "First 10 lines:"
        head -n 10 "$file"
        return 0
    fi

    echo "No caption data produced."
    if [ -s "$log_file" ]; then
        echo "ffmpeg stderr (last 10 lines):"
        tail -n 10 "$log_file"
    fi
    return 1
}

ffprobe_inventory() {
    local label="$1"
    local url="$2"
    local json_file="$3"
    local err_file="$4"

    echo ""
    echo "=== ffprobe stream inventory (${label}) ==="
    if ffprobe -user_agent "$HTTP_USER_AGENT" -v quiet -print_format json -show_streams -show_format "$url" >"$json_file" 2>"$err_file"; then
        if [ -s "$json_file" ]; then
            python3 - <<'PY' "$json_file"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

streams = data.get("streams", [])
if not streams:
    print("(no streams reported)")
for idx, stream in enumerate(streams):
    codec_type = stream.get("codec_type", "?")
    codec_name = stream.get("codec_name", "?")
    tags = stream.get("tags") or {}
    language = tags.get("language", "?")
    title = tags.get("title", "")
    extra = []
    if stream.get("width") and stream.get("height"):
        extra.append(f"{stream['width']}x{stream['height']}")
    if stream.get("codec_tag_string"):
        extra.append(stream["codec_tag_string"])
    info = " ".join(extra)
    print(f"[{idx}] type={codec_type} codec={codec_name} lang={language} title={title} {info}".rstrip())
PY
            return 0
        fi
    fi

    echo "(ffprobe did not return parseable stream data)"
    if [ -s "$err_file" ]; then
        tail -n 10 "$err_file"
    fi
}

echo "CC diagnostic"
echo "Master URL:   $MASTER_URL"
echo "User-Agent:   $HTTP_USER_AGENT"
echo "Capture sec:  $SEG_SEC"
echo ""

MANIFEST_FILE="${TMP_DIR}/master.m3u8"
if ! curl -fsSL -A "$HTTP_USER_AGENT" "$MASTER_URL" -o "$MANIFEST_FILE"; then
    echo "Failed to fetch master manifest." >&2
    exit 1
fi

echo "=== Manifest inventory ==="
python3 - <<'PY' "$MANIFEST_FILE" "$MASTER_URL"
import sys
from urllib.parse import urljoin

manifest_path, master_url = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8", errors="replace") as fh:
    lines = [line.rstrip("\n") for line in fh]

def parse_attrs(chunk):
    attrs = {}
    current = []
    in_quote = False
    for char in chunk:
        if char == '"':
            in_quote = not in_quote
        if char == ',' and not in_quote:
            item = ''.join(current).strip()
            if '=' in item:
                key, value = item.split('=', 1)
                attrs[key] = value.strip('"')
            current = []
        else:
            current.append(char)
    item = ''.join(current).strip()
    if '=' in item:
        key, value = item.split('=', 1)
        attrs[key] = value.strip('"')
    return attrs

media_entries = []
variants = []

i = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith("#EXT-X-MEDIA:"):
        media_entries.append(parse_attrs(line.split(":", 1)[1]))
    elif line.startswith("#EXT-X-STREAM-INF:"):
        attrs = parse_attrs(line.split(":", 1)[1])
        j = i + 1
        while j < len(lines) and lines[j].strip().startswith("#"):
            j += 1
        if j < len(lines):
            variants.append({
                "url": urljoin(master_url, lines[j].strip()),
                **attrs,
            })
        i = j
    i += 1

print("Media tracks:")
if not media_entries:
    print("  (none)")
for idx, entry in enumerate(media_entries, 1):
    kind = entry.get("TYPE", "?")
    group = entry.get("GROUP-ID", "?")
    name = entry.get("NAME", "?")
    lang = entry.get("LANGUAGE", "?")
    uri = entry.get("URI", "")
    detail = urljoin(master_url, uri) if uri else "(embedded/no URI)"
    print(f"  [{idx}] TYPE={kind} GROUP={group} NAME={name} LANG={lang} URI={detail}")

print("")
print("Closed captions present:", "yes" if any(e.get("TYPE") == "CLOSED-CAPTIONS" for e in media_entries) else "no")
print("Subtitle renditions present:", "yes" if any(e.get("TYPE") == "SUBTITLES" for e in media_entries) else "no")

print("")
print("Video/audio variants:")
if not variants:
    print("  (none)")
for idx, entry in enumerate(variants, 1):
    bw = entry.get("BANDWIDTH", "?")
    res = entry.get("RESOLUTION", "?")
    codecs = entry.get("CODECS", "?")
    audio = entry.get("AUDIO", "")
    subtitles = entry.get("SUBTITLES", "")
    cc = entry.get("CLOSED-CAPTIONS", "")
    print(
        f"  [{idx}] BW={bw} RES={res} CODECS={codecs} AUDIO={audio} SUBTITLES={subtitles} CC={cc} URL={entry['url']}"
    )

best_url = ""
if variants:
    variants.sort(key=lambda item: int(item.get("BANDWIDTH", "0") or "0"), reverse=True)
    best_url = variants[0]["url"]
print("")
print(f"BEST_URL={best_url}")
PY

BEST_URL="$(python3 - <<'PY' "$MANIFEST_FILE" "$MASTER_URL"
import sys
from urllib.parse import urljoin

manifest_path, master_url = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8", errors="replace") as fh:
    lines = [line.rstrip("\n") for line in fh]

def parse_attrs(chunk):
    attrs = {}
    current = []
    in_quote = False
    for char in chunk:
        if char == '"':
            in_quote = not in_quote
        if char == ',' and not in_quote:
            item = ''.join(current).strip()
            if '=' in item:
                key, value = item.split('=', 1)
                attrs[key] = value.strip('"')
            current = []
        else:
            current.append(char)
    item = ''.join(current).strip()
    if '=' in item:
        key, value = item.split('=', 1)
        attrs[key] = value.strip('"')
    return attrs

variants = []
i = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith("#EXT-X-STREAM-INF:"):
        attrs = parse_attrs(line.split(":", 1)[1])
        j = i + 1
        while j < len(lines) and lines[j].strip().startswith("#"):
            j += 1
        if j < len(lines):
            variants.append((int(attrs.get("BANDWIDTH", "0") or "0"), urljoin(master_url, lines[j].strip())))
        i = j
    i += 1

variants.sort(reverse=True)
print(variants[0][1] if variants else "")
PY
)"

if [ -z "$BEST_URL" ]; then
    echo ""
    echo "Could not determine BEST_URL from manifest."
    exit 1
fi

ffprobe_inventory "master" "$MASTER_URL" "${TMP_DIR}/ffprobe-master.json" "${TMP_DIR}/ffprobe-master.log"
ffprobe_inventory "best variant" "$BEST_URL" "${TMP_DIR}/ffprobe-best.json" "${TMP_DIR}/ffprobe-best.log"

echo ""
echo "=== Local sample capture ==="
SAMPLE_TS="${TMP_DIR}/best-sample.ts"
SAMPLE_LOG="${TMP_DIR}/best-sample.log"
if ffmpeg -y -user_agent "$HTTP_USER_AGENT" -i "$BEST_URL" -t "$SEG_SEC" -map 0:v:0 -map 0:a? -c copy -f mpegts "$SAMPLE_TS" \
    > /dev/null 2>"$SAMPLE_LOG"; then
    SAMPLE_BYTES=$(wc -c < "$SAMPLE_TS" | tr -d ' ')
    echo "Sample TS: ${SAMPLE_TS} ($(human_size "$SAMPLE_BYTES"))"
else
    echo "Failed to capture local TS sample."
    tail -n 10 "$SAMPLE_LOG"
fi

declare -A METHOD_FILES=()
declare -A METHOD_LOGS=()
declare -A METHOD_DESCRIPTIONS=()

METHOD_FILES[A]="${TMP_DIR}/test_cc_a.srt"
METHOD_FILES[B]="${TMP_DIR}/test_cc_b.srt"
METHOD_FILES[C]="${TMP_DIR}/test_cc_c.srt"
METHOD_FILES[D]="${TMP_DIR}/test_cc_d.srt"

METHOD_LOGS[A]="${TMP_DIR}/test_cc_a.log"
METHOD_LOGS[B]="${TMP_DIR}/test_cc_b.log"
METHOD_LOGS[C]="${TMP_DIR}/test_cc_c.log"
METHOD_LOGS[D]="${TMP_DIR}/test_cc_d.log"

METHOD_DESCRIPTIONS[A]="Direct subtitle stream mapping"
METHOD_DESCRIPTIONS[B]="lavfi movie=... [out+subcc]"
METHOD_DESCRIPTIONS[C]="Direct subtitle mapping with codec:s srt"
METHOD_DESCRIPTIONS[D]="extractcc video filter"

echo ""
echo "=== Caption extraction attempts ==="

echo ""
echo "Running Method A: ${METHOD_DESCRIPTIONS[A]}"
ffmpeg -y -user_agent "$HTTP_USER_AGENT" -i "$MASTER_URL" -t "$SEG_SEC" -map 0:s:0? -c:s srt "${METHOD_FILES[A]}" \
    > /dev/null 2>"${METHOD_LOGS[A]}" || true
summarize_output "Method A" "${METHOD_FILES[A]}" "${METHOD_LOGS[A]}" || true

echo ""
echo "Running Method B: ${METHOD_DESCRIPTIONS[B]}"
if [ -s "$SAMPLE_TS" ]; then
    ffmpeg -y -f lavfi -i "movie=${SAMPLE_TS}[out+subcc]" -map 0:s -c:s srt "${METHOD_FILES[B]}" \
        > /dev/null 2>"${METHOD_LOGS[B]}" || true
else
    printf 'Sample TS unavailable; Method B skipped.\n' > "${METHOD_LOGS[B]}"
fi
summarize_output "Method B" "${METHOD_FILES[B]}" "${METHOD_LOGS[B]}" || true

echo ""
echo "Running Method C: ${METHOD_DESCRIPTIONS[C]}"
ffmpeg -y -user_agent "$HTTP_USER_AGENT" -i "$BEST_URL" -t "$SEG_SEC" -codec:s srt -map 0:s? "${METHOD_FILES[C]}" \
    > /dev/null 2>"${METHOD_LOGS[C]}" || true
summarize_output "Method C" "${METHOD_FILES[C]}" "${METHOD_LOGS[C]}" || true

echo ""
echo "Running Method D: ${METHOD_DESCRIPTIONS[D]}"
if ffmpeg -hide_banner -filters | grep -q ' extractcc '; then
    ffmpeg -y -user_agent "$HTTP_USER_AGENT" -i "$BEST_URL" -t "$SEG_SEC" -filter_complex "[0:v]extractcc[sub]" -map "[sub]" -c:s srt "${METHOD_FILES[D]}" \
        > /dev/null 2>"${METHOD_LOGS[D]}" || true
else
    printf 'extractcc filter not available in this ffmpeg build.\n' > "${METHOD_LOGS[D]}"
fi
summarize_output "Method D" "${METHOD_FILES[D]}" "${METHOD_LOGS[D]}" || true

echo ""
echo "=== Summary ==="
WORKING=0
for method in A B C D; do
    if [ -s "${METHOD_FILES[$method]}" ]; then
        WORKING=$((WORKING + 1))
        echo "Method ${method}: WORKED (${METHOD_DESCRIPTIONS[$method]})"
    else
        echo "Method ${method}: no usable caption data"
    fi
done

if [ "$WORKING" -eq 0 ]; then
    echo "No caption extraction method produced data."
    echo "Quirk summary: either captions are absent, encrypted, or ffmpeg cannot decode this stream's caption format directly."
else
    echo "Detected ${WORKING} working caption extraction method(s)."
    echo "Review the per-method previews above to determine whether captions arrive as subtitle renditions or embedded video captions."
fi

echo ""
echo "Temp files were stored in: $TMP_DIR"
echo "They will be removed when the script exits."
