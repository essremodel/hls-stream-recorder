# README visuals

- `hero.png`: original generated charcoal/cyan broadcast-themed branding artwork. It is not a recording screenshot.
- `help-output.txt`: full stdout captured by running `bash record.sh --help` with Bash 5.3.15 from a clean checkout. The help command exits before stream probes or recording.
- `terminal-help.png`: the usage and options portion of that exact output, typeset in a monospace terminal-style panel for readability. The image is a presentation of captured text, not a screenshot of a running capture session. Arguments and examples remain available in the text file.

The existing help output identifies `--update-channels` as a future feature. No output was invented to suggest that the stub or an experimental mode was tested. The images contain no personal streams or recording transcripts.

To refresh the source capture from the repository root:

```bash
bash record.sh --help > assets/help-output.txt
```

If the options change, update the image from the new captured output and inspect it before committing.
