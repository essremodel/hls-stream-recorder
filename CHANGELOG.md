# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Built-in stream catalog files: `channels.conf`, `channels.sh`, `streams.example.txt`, and a gitignored `streams.txt` template for personal channels.
- Interactive stream picker with category-grouped menus, default selection, short-name lookup, manual URL entry, and offline alternate suggestions.
- New CLI shortcuts: `--stream`, `--mode`, `--test-streams`, and `--update-channels` (stub).
- Session-cached stream health checks with capped parallel probing and per-stream resolution/bitrate summaries.
- Experimental keyword monitor mode with rolling-buffer retention, per-segment caption scanning, and keyword-triggered kept folders.
- `debug_cc.sh` to inspect manifest tracks and test multiple caption extraction methods before enabling monitor mode on a stream.
- `keywords.txt` with default ESS/CHD-related phrases for monitor mode.
- Signal cleanup that removes temp files and terminates background recorder processes on exit, `Ctrl+C`, or termination.
- One retry attempt for failed recording segments, with retry logging in the terminal output.
- CLI flags for `--help`, `--quiet`, `--url`, `--output`, `--monitor`, `--keywords`, `--until`, and `--segment-length`.
- Per-segment stall protection that kills hung `ffmpeg` processes after 2x the requested segment length.
- Troubleshooting and contributing guidance in the README.

### Changed

- Stream selection now happens before recording mode selection, while keeping direct `--url` and positional URL input working.
- Per-stream notes can now carry optional `user-agent=` metadata that is reused across `curl`, `ffprobe`, and `ffmpeg` requests.
- Hardened duration and time parsing, including support for inputs like `12am`, `12pm`, and bare-hour values such as `2pm`.
- Added validation to reject invalid durations, malformed times, and record-now durations that would cross midnight.
- Replaced several platform-specific shell idioms with more portable helpers for progress bars, temp files, current time, and output-folder opening.
- Quiet mode now suppresses progress animations while keeping start/end log lines and summaries.
- Playlist fetches now follow redirects and send a configurable HTTP User-Agent for HLS endpoints that reject default clients.
- Monitor mode now auto-detects caption extraction methods at startup and falls back to a warning-only recording path when captions are unavailable.

### Fixed

- Reduced the chance of orphaned background `ffmpeg` processes during interrupted runs.
- Added a clear failure message when `python3` is missing instead of failing later in parsing helpers.
- Added overlap merging for adjacent monitor matches, low-disk buffer flushing, and stream refresh handling after monitor segment failures.
