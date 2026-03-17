# SyncMusic

`SyncMusic` is a local macOS menu bar utility that materializes Apple Music Smart Playlists into ordinary playlists that Soundiiz and similar transfer services can see.

## What It Does

- Enumerates local Apple Music Smart Playlists through Music automation
- Creates paired ordinary playlists with a configurable prefix
- Keeps those paired playlists in exact sync with the smart playlists
- Optionally shards oversized playlists for `Qobuz via Soundiiz`
- Stores local state and config in `~/Library/Application Support/SyncMusic`
- Writes structured diagnostics under `~/Library/Application Support/SyncMusic/logs` and `~/Library/Application Support/SyncMusic/runs`

## Build and Run

Development run:

```bash
swift run --disable-sandbox SyncMusic
```

Build a menu bar `.app` bundle:

```bash
./scripts/build-app.sh
open dist/SyncMusic.app
```

Verification checks:

```bash
swift run --disable-sandbox SyncMusicChecks
```

## Diagnostics

- The menu bar UI exposes `View Logs`, `Open Diagnostics Folder`, and `Copy Diagnostics Summary`.
- The latest structured log is written to `~/Library/Application Support/SyncMusic/logs/syncmusic.log.jsonl`.
- The latest run summary is written to `~/Library/Application Support/SyncMusic/runs/last-run.json`.
- If the app terminates mid-sync, `~/Library/Application Support/SyncMusic/runs/crash-context.json` captures the unfinished run context.
- Log retention is configurable in Settings.

## First-Run Notes

- macOS will prompt for permission to control the Music app.
- `Launch at Login` is only meaningful when running the bundled `.app`.
- Apple Music `Sync Library` must be enabled if you want third-party transfer services to see the generated playlists.
- Transfer-service visibility can lag behind local playlist changes while Apple Music syncs.
