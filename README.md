# 📡 HLS Stream Recorder — Max Quality

A bash script that records HLS live streams at the highest available bitrate. Automatically parses the master playlist, selects the best variant, runs a quality test, and records in timed segments with optional closed-caption extraction.

![Shell](https://img.shields.io/badge/Shell-Bash-green) ![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-blue) ![License](https://img.shields.io/badge/License-MIT-yellow)

---

## Features

- **Built-in channel guide** — curated free public HLS streams grouped by category in `channels.conf`
- **Custom streams** — add personal or private HLS endpoints in `streams.txt` without committing them
- **Interactive stream picker** — choose by menu number, short name, or manual URL before recording mode selection
- **Parallel stream health checks** — test the full catalog with `t` in the picker or `--test-streams`
- **Auto-selects highest quality** — parses the master `.m3u8` and picks the top bitrate/resolution variant
- **Pre-flight quality test** — records a 15-second sample and verifies resolution before committing
- **Four recording modes:**
  - **Scheduled** — two preset time windows with 5-minute early cushion
  - **Record Now (duration)** — start immediately for N minutes
  - **Record Now (time range)** — specify custom start/end times (12h or 24h format)
  - **Keyword monitor** — rolling retention on caption keyword hits
- **Keyword monitor (experimental)** — rolling 2.5-minute segments with keyword-triggered retention
- **5-minute segments** — fault-tolerant chunking so a stream hiccup doesn't lose everything
- **Automatic retry** — retries a failed segment once after a short pause
- **Stall protection** — kills a segment attempt that runs for more than 2x its target duration
- **Closed captions** — attempts `.srt` extraction per segment
- **Live progress UI** — animated spinners, progress bars, file sizes, per-segment and overall progress
- **CLI flags** — supports `--stream`, `--test-streams`, `--mode`, `--url`, `--output`, and monitor options
- **Detailed stream probe** — displays codec, resolution, FPS, color space, bitrate before recording

## Requirements

| Tool | Install |
|------|---------|
| `ffmpeg` | `brew install ffmpeg` (macOS) / `apt install ffmpeg` (Linux) |
| `ffprobe` | Included with ffmpeg |
| `curl` | Pre-installed on macOS/most Linux |
| `python3` | Pre-installed on macOS/most Linux |

## Usage

```bash
chmod +x record.sh
./record.sh
```

Run with no arguments to open the built-in stream picker. You can also skip the picker with `--stream` or bypass the catalog entirely with `--url` or a positional URL.

### CLI Flags

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show usage and exit |
| `-q`, `--quiet` | Suppress progress animations and countdown redraws |
| `--stream <ref>` | Select a stream by menu number or short name, such as `1` or `cbs4` |
| `--test-streams` | Probe every configured stream and report which ones are live |
| `--update-channels` | Placeholder for future guide sync; currently prints a stub message and exits |
| `--mode <mode>` | Skip the mode prompt with `1-4`, `scheduled`, `duration`, `range`, or `monitor` |
| `--monitor` | Enable keyword monitor mode (experimental) |
| `--keywords <file>` | Use a custom keywords file for monitor mode |
| `--until <time>` | Stop monitor mode at a specific time |
| `--segment-length <sec>` | Override the monitor segment length (default: 150) |
| `--url <url>` | Set the HLS master playlist URL |
| `--output <dir>` | Write recordings to a custom output directory |

### Examples

```bash
./record.sh
./record.sh --stream cbs4
./record.sh --stream 1 --mode 2
./record.sh --stream abc --monitor
./record.sh --test-streams
./record.sh --url https://your-stream.com/index.m3u8 --output /tmp/hls-capture
./record.sh https://your-stream.com/index.m3u8
echo 1 | ./record.sh --quiet --stream cbs4
./record.sh --monitor --keywords ./keywords.txt --until 23:00
```

## Stream Selection

The recorder ships with a built-in guide of free public HLS channels in `channels.conf`. The first entry is the default stream.

For private or personal URLs, edit `streams.txt`. A committed template lives in `streams.example.txt`, and `streams.txt` is gitignored so your private endpoints stay local.

Both files use the same pipe-delimited format:

```text
category|short_name|display_name|url|notes
```

If you do not pass `--stream` or `--url`, the script shows a stream picker before the recording mode menu. You can:

- Press `Enter` to use the default built-in stream
- Type a menu number such as `1`
- Type a short name such as `cbs4`, `abc`, or `cspan1`
- Type `u` to enter a raw HLS URL manually
- Type `t` to run a live check across the whole catalog

Manual URLs, built-in channels, and custom streams are quick-probed before the mode menu. If a stream is offline, the picker offers retry, alternate-stream, back, and manual-URL options.

### Test All Streams

```bash
./record.sh --test-streams
```

This runs up to 5 probes in parallel, caches results for the current session, and reports online/offline status with resolution and bitrate when available. A full pass can take longer when several endpoints are slow or timing out.

After stream selection you'll see the recording mode menu:

```
  Choose recording mode:

    1)  Scheduled — 5:55p→7:00p  then  9:55p→11:00p
    2)  Record now — enter a custom duration
    3)  Record now — enter start & end times
    4)  ⚡ Keyword monitor (experimental) — record on keyword detection

  Select [1/2/3/4]:
```

### Mode 1: Scheduled (default)

Just press `1` and walk away. The script waits for the first window, records, waits for the second, records, then shows a summary.

```
1
```

### Mode 2: Record Now — Duration

Start recording immediately for a set number of minutes.

```
2
How many minutes to record? 30
```

### Mode 3: Record Now — Time Range

Specify exact start and end times. Accepts multiple formats:

```
3
Start time: 2:30pm
End time: 4:00pm
```

**Accepted time formats:**

| Input | Interpreted As |
|-------|---------------|
| `14:30` | 2:30 PM (24h) |
| `2:30pm` | 2:30 PM |
| `2:30PM` | 2:30 PM |
| `9am` | 9:00 AM |
| `21:00` | 9:00 PM |

## Adding Channels

Edit `channels.conf` to add or remove built-in guide entries:

```text
Category|short_name|Display Name|https://url/master.m3u8|Optional notes
```

Use `streams.txt` for personal streams instead of editing `channels.conf`.

If a stream needs a custom User-Agent, add it in the notes field. Quote the value when it contains semicolons:

```text
My Streams|strict-feed|Strict Feed|https://example.com/live.m3u8|user-agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"; Requires desktop UA
```

## Channel Sources

Built-in channels are sourced from publicly available free streams. Many originate from [iptv-org/iptv](https://github.com/iptv-org/iptv) and similar open directories. URLs may change or disappear over time, so use `t` in the picker or `--test-streams` to verify availability.

## Keyword Monitor Mode (Experimental)

Keyword monitor mode records continuously into a rolling on-disk buffer, extracts captions per segment when possible, and keeps only the segments around a keyword hit. By default it keeps roughly 5 minutes before and 5 minutes after a match, using 150-second segments.

### Monitor Flags

```bash
./record.sh --monitor
./record.sh --monitor --keywords /path/to/my_keywords.txt
./record.sh --monitor --until 23:00
./record.sh --monitor --segment-length 120
```

- `--monitor` switches directly into mode 4.
- `--keywords` overrides the default `keywords.txt`.
- `--until` stops monitor mode at the specified local time.
- `--segment-length` changes the rolling segment size in seconds.

### `keywords.txt` Format

The default keyword file is `keywords.txt`. Put one keyword or phrase per line. Matching is case-insensitive substring matching, so `ESS` matches `...team from ESS responded...` and `Top Edge` matches longer caption lines containing that phrase.

### Monitor Output Layout

```text
recording_monitor_20260313/
├── buffer/
│   ├── seg_000047.mp4
│   ├── seg_000047.srt
│   ├── seg_000047.txt
│   └── ...
├── kept/
│   ├── match_001_seg_000048-000052/
│   │   ├── seg_000048.mp4
│   │   ├── seg_000048.srt
│   │   ├── seg_000048.txt
│   │   └── match_info.txt
│   └── ...
└── monitor.log
```

`monitor.log` records startup details, per-segment status, caption text, keyword hits, retention windows, and cleanup actions.

### Known Limitations

- CC availability depends entirely on the source stream and ffmpeg’s ability to decode that stream’s caption format.
- Embedded EIA-608/708 extraction is highly source- and build-dependent; this repo currently auto-detects supported methods and warns when none work.
- Keyword matching is plain text substring matching only. There is no regex or fuzzy matching yet.
- Buffer retention works on segment boundaries, not exact subtitle timestamps, so match windows are only precise to about ±1 segment.
- Some streams advertise `CLOSED-CAPTIONS` in the manifest but still expose only `timed_id3` data to ffmpeg, which means monitor mode may run without any usable caption text.

### Debugging CC Issues

Run the diagnostic tool before trusting monitor mode on a new stream:

```bash
chmod +x debug_cc.sh
./debug_cc.sh https://your-stream.com/index.m3u8
```

`debug_cc.sh` inspects the manifest, reports subtitle/CC metadata, and tests the caption extraction paths used by the recorder. If every method reports empty output, monitor mode will still record and rotate segments, but keyword-triggered retention will not fire.

## Configuration

Edit the variables at the top of the script to customize:

```bash
# Segment length (seconds)
SEGMENT_SEC=300  # 5 minutes

# Scheduled windows (24h format)
WIN1_START_HOUR=17; WIN1_START_MIN=55   # 5:55 PM
WIN1_END_HOUR=19;   WIN1_END_MIN=0      # 7:00 PM

WIN2_START_HOUR=21; WIN2_START_MIN=55   # 9:55 PM
WIN2_END_HOUR=23;   WIN2_END_MIN=0      # 11:00 PM
```

The built-in channel guide lives in `channels.conf`, and personal streams live in `streams.txt`. You can also override the output folder at runtime with `--output /path/to/folder`.

If a provider is strict about request headers, you can override the default HTTP User-Agent:

```bash
HLS_RECORDER_USER_AGENT="Mozilla/5.0 Custom Client" ./record.sh https://your-stream.com/index.m3u8
```

## Output

Files are saved to a date-stamped folder next to the script:

```
recording_20260313/
├── segment_001.mp4
├── segment_001.srt    (if captions available)
├── segment_002.mp4
├── segment_002.srt
├── ...
```

On macOS, the output folder opens automatically in Finder when recording completes. On Linux, the script uses `xdg-open` when available in a GUI session.

### Summary

After all windows finish, you get a full report:

```
╔═══════════════════════════════════════════════════════════╗
║  Recording Complete — 23:00:04                            ║
╚═══════════════════════════════════════════════════════════╝

  Quality     1080p (highest variant)
  Windows     2
  Segments    24 ok  0 failed  /  24 total
  Total size  8.2 GB
  Captions    24 .srt files
  Duration    192m 14s
  Location    /path/to/recording_20260313/
```

If a segment needs intervention, you may also see lines like:

```text
    ↻ Retry 2/2 in 5s after segment failure
    ⚠ Segment stalled and hit the 2x timeout (300s → 600s)
```

## How It Works

1. **Fetch & parse** the master `.m3u8` playlist
2. **Rank variants** by bandwidth, select the highest
3. **Probe** the selected variant with `ffprobe` for codec details
4. **Test** — record 15 seconds, verify file size and resolution
5. **Wait** for the scheduled start time (or start immediately in on-demand mode)
6. **Record** in 5-minute segments using `ffmpeg -c copy` (no re-encoding)
7. **Retry** a failed segment once after a 5-second pause
8. **Enforce a timeout** if a segment stalls far beyond its target duration
9. **Extract captions** in parallel from the master URL
10. **Repeat** for each recording window
11. **Summarize** and open the output folder

### Monitor Mode Flow

1. **Parse & probe** the stream as usual to find the best live variant.
2. **Run a CC diagnostic** at startup to auto-detect a working caption extraction path, if any.
3. **Record** rolling segments into `buffer/`.
4. **Extract captions** to `.srt` and cleaned `.txt` sidecars.
5. **Scan** the cleaned text against `keywords.txt`.
6. **Flag** the matching segment plus the configured before/after buffer window.
7. **Promote** flagged segments into `kept/` as older buffer segments age out.
8. **Delete** non-flagged segments to keep disk usage bounded.
9. **Merge** overlapping match windows into a single kept folder.

## Tips

- **Segment duration** — 5 minutes is a good balance between fault tolerance and file count. Increase `SEGMENT_SEC` for fewer, larger files.
- **Adding more windows** — add `WIN3_*` variables and append them to the arrays in the scheduled-mode case block.
- **Cron/launchd** — to run unattended, pass both `--stream` and `--mode`, for example `./record.sh --quiet --stream cbs4 --mode 1`.
- **Monitor mode** — for long runs, point `--output` at a disk with plenty of free space and keep `monitor.log` under review for CC warnings.
- **Disk space** — a 1080p HLS stream typically runs 3–6 GB/hour depending on bitrate. Plan accordingly for multi-hour recordings.

## Troubleshooting

### Stream playlist fails to load

- Verify that the URL points to the HLS master playlist, not a web page.
- Some providers rotate or expire playlist URLs. Refresh the source URL and try again.
- The recorder follows redirects automatically and sends a browser-like User-Agent by default.
- If the provider still blocks requests, try setting `HLS_RECORDER_USER_AGENT` to match a browser UA string you know works.
- Test the playlist directly with `curl -I` or `ffprobe` to confirm it still resolves.

### `ffmpeg` hangs or a segment times out

- The recorder now kills a segment attempt if it runs for more than 2x the requested segment length.
- If this happens repeatedly, the upstream stream may be unstable or the selected URL may no longer be valid.
- Try a shorter recording window first to confirm the stream is still healthy.

### Monitor mode finds no keywords even though the stream should have captions

- Run `./debug_cc.sh` against the same master playlist URL first.
- If the diagnostic reports `TYPE=CLOSED-CAPTIONS` but every extraction method is empty, ffmpeg is not decoding usable text from that stream in the current environment.
- Monitor mode will still rotate segments in `buffer/`, but it will warn that keyword retention is effectively disabled.

### Recording stops because the disk fills up

- Check available disk space before long runs.
- Use `--output` to target a volume with more free space.
- Delete old `recording_*` folders and large `.mp4` files you no longer need.

## Contributing

- Keep changes incremental and avoid rewriting the capture flow unless a bug requires it.
- Run `bash -n record.sh` before opening a pull request.
- Update `README.md` and `CHANGELOG.md` when behavior or CLI flags change.

## License

MIT
