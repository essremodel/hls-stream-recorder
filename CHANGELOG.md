# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Signal cleanup that removes temp files and terminates background recorder processes on exit, `Ctrl+C`, or termination.
- One retry attempt for failed recording segments, with retry logging in the terminal output.
- CLI flags for `--help`, `--quiet`, `--url`, and `--output`.
- Per-segment stall protection that kills hung `ffmpeg` processes after 2x the requested segment length.
- Troubleshooting and contributing guidance in the README.

### Changed

- Hardened duration and time parsing, including support for inputs like `12am`, `12pm`, and bare-hour values such as `2pm`.
- Added validation to reject invalid durations, malformed times, and record-now durations that would cross midnight.
- Replaced several platform-specific shell idioms with more portable helpers for progress bars, temp files, current time, and output-folder opening.
- Quiet mode now suppresses progress animations while keeping start/end log lines and summaries.
- Playlist fetches now follow redirects and send a configurable HTTP User-Agent for HLS endpoints that reject default clients.

### Fixed

- Reduced the chance of orphaned background `ffmpeg` processes during interrupted runs.
- Added a clear failure message when `python3` is missing instead of failing later in parsing helpers.
