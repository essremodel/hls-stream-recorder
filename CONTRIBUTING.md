# Contributing

Keep changes incremental and preserve the capture flow unless a bug requires a change. Retain the README's command reference, recording modes, caption diagnostics, configuration, and troubleshooting when improving its presentation.

## Local checks

Use Bash 4 or newer, as described in [Requirements](./README.md#requirements).

```bash
for file in record.sh channels.sh debug_cc.sh; do
  bash -n "$file" || exit 1
done
bash record.sh --help
shellcheck record.sh channels.sh debug_cc.sh
git diff --check
```

ShellCheck is an optional development tool, not a recorder dependency. Existing ShellCheck findings are present in the source; distinguish new findings from the baseline. There is no automated test suite or CI workflow in this repository.

The help command exits without probing or recording. For changes to actual capture behavior, use a controlled stream you are authorized to record, keep the run short, and report what you tested. Caption availability must be checked independently; successful video recording does not establish that keyword retention works.

## Documentation and assets

Update `README.md` and `CHANGELOG.md` when behavior or CLI flags change. Verify image paths, links, anchors, and command examples. Inspect presentation changes at desktop and narrow widths in both themes. Keep experimental features and the channel-update stub clearly labeled.

Do not commit personal `streams.txt` files, private URLs, recording outputs, or caption transcripts. The README capture is documented in [assets/README.md](./assets/README.md). Preserve the existing licensing note; a license badge requires a corresponding license file.
