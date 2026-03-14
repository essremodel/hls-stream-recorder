# 📡 HLS Stream Recorder — Max Quality

A bash script that records HLS live streams at the highest available bitrate. Automatically parses the master playlist, selects the best variant, runs a quality test, and records in timed segments with optional closed-caption extraction.

![Shell](https://img.shields.io/badge/Shell-Bash-green) ![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-blue) ![License](https://img.shields.io/badge/License-MIT-yellow)

---

## Features

- **Auto-selects highest quality** — parses the master `.m3u8` and picks the top bitrate/resolution variant
- **Pre-flight quality test** — records a 15-second sample and verifies resolution before committing
- **Three recording modes:**
  - **Scheduled** — two preset time windows with 5-minute early cushion
  - **Record Now (duration)** — start immediately for N minutes
  - **Record Now (time range)** — specify custom start/end times (12h or 24h format)
- **5-minute segments** — fault-tolerant chunking so a stream hiccup doesn't lose everything
- **Automatic retry** — retries a failed segment once after a short pause
- **Stall protection** — kills a segment attempt that runs for more than 2x its target duration
- **Closed captions** — attempts `.srt` extraction per segment
- **Live progress UI** — animated spinners, progress bars, file sizes, per-segment and overall progress
- **CLI flags** — supports `--help`, `--quiet`, `--url`, and `--output`
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
./record.sh --url https://your-stream.com/index.m3u8
```

Pass the HLS master playlist URL either as the first argument or with `--url`. If you prefer, you can edit the default `MASTER_URL` placeholder near the top of `record.sh` instead.

### CLI Flags

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Show usage and exit |
| `-q`, `--quiet` | Suppress progress animations and countdown redraws |
| `--url <url>` | Set the HLS master playlist URL |
| `--output <dir>` | Write recordings to a custom output directory |

### Examples

```bash
./record.sh https://your-stream.com/index.m3u8
./record.sh --url https://your-stream.com/index.m3u8 --output /tmp/hls-capture
echo 1 | ./record.sh --quiet https://your-stream.com/index.m3u8
```

On launch you'll see a mode selection menu:

```
  Choose recording mode:

    1)  Scheduled — 5:55p→7:00p  then  9:55p→11:00p
    2)  Record now — enter a custom duration
    3)  Record now — enter start & end times

  Select [1/2/3]:
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

## Configuration

Edit the variables at the top of the script to customize:

```bash
# Stream URL from the first CLI argument, with a placeholder default
MASTER_URL="${1:-https://example.com/stream/index.m3u8}"

# Segment length (seconds)
SEGMENT_SEC=300  # 5 minutes

# Scheduled windows (24h format)
WIN1_START_HOUR=17; WIN1_START_MIN=55   # 5:55 PM
WIN1_END_HOUR=19;   WIN1_END_MIN=0      # 7:00 PM

WIN2_START_HOUR=21; WIN2_START_MIN=55   # 9:55 PM
WIN2_END_HOUR=23;   WIN2_END_MIN=0      # 11:00 PM
```

You can also override the output folder at runtime with `--output /path/to/folder`.

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

## Tips

- **Segment duration** — 5 minutes is a good balance between fault tolerance and file count. Increase `SEGMENT_SEC` for fewer, larger files.
- **Adding more windows** — add `WIN3_*` variables and append them to the arrays in the scheduled-mode case block.
- **Cron/launchd** — to run unattended, pipe `1` into stdin: `echo 1 | ./record.sh --quiet https://your-stream.com/index.m3u8` and it will use scheduled mode with no interaction.
- **Disk space** — a 1080p HLS stream typically runs 3–6 GB/hour depending on bitrate. Plan accordingly for multi-hour recordings.

## Troubleshooting

### Stream playlist fails to load

- Verify that the URL points to the HLS master playlist, not a web page.
- Some providers rotate or expire playlist URLs. Refresh the source URL and try again.
- Test the playlist directly with `curl -I` or `ffprobe` to confirm it still resolves.

### `ffmpeg` hangs or a segment times out

- The recorder now kills a segment attempt if it runs for more than 2x the requested segment length.
- If this happens repeatedly, the upstream stream may be unstable or the selected URL may no longer be valid.
- Try a shorter recording window first to confirm the stream is still healthy.

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
