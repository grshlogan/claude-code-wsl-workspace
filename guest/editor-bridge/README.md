# Editor bridge — guest side

`claude-windows-editor` is the guest half of the prompt-only editor bridge.
It is spawned by Claude Code as `$EDITOR`/`$VISUAL` (registered through the
`codium` shim, see below), writes a request into
`/tmp/claude-editor-requests/`, and waits for the Windows-side watcher
(`host/daily/claude-editor-bridge.ps1 -Watch`) to edit the file with the
configured GUI editor. Without a watcher it falls back to guest nano after
20 seconds.

## Argument styles

- legacy: `<path>`
- Claude Code >= 2.1 (whitelisted-GUI convention): `-g <path>:<line>` — the
  position suffix is stripped before matching.

## Deployment

```
install -o claude -g claude -m 700 claude-windows-editor \
  /home/claude/.local/bin/claude-windows-editor
```

Live dependency: Claude Code's editor whitelist (verified on v2.1.281,
2026-10-15). `/usr/local/bin/codium` on the guest is a shim that places
this wrapper under that whitelist so the CLI stays visible with the
`Save and close editor to continue...` banner. If a Claude Code update
changes the whitelist, re-verify the shim name.
