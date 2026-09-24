# Activity+ — project notes

macOS system monitor (Vitals alternative + extras). SwiftPM, no Xcode project. Personal use first.

## Build, test, verify
- Toolchain: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (the default CLT has an old SDK). `scripts/build-app.sh` sets it.
- `scripts/build-app.sh --run` → `dist/Activity+.app` (ad-hoc signed) and launch.
- `swift test` — Swift Testing, pure logic in ActivityCore.
- **Visual check without screen-recording permission:** `ACTIVITYPLUS_SNAPSHOTS=/tmp/shots [ACTIVITYPLUS_PAGES=overview,metric:cpu,…] [ACTIVITYPLUS_WARMUP=12] dist/Activity+.app/Contents/MacOS/ActivityPlus` renders every page, the menu bar panel and both share cards to PNG, then quits. `screencapture` does not work from the agent shell.
- `.build/debug/aplus [--memory|--json]` to sanity-check numbers against `top`.

## Architecture
- `ActivityCore/SystemSampler` builds one `SystemSnapshot` per tick from the samplers; all samplers keep previous counters, so call only from one serial queue (`Monitor`).
- Process list comes from `/bin/ps` (setuid) so root processes are visible; `proc_pid_rusage` refines own processes. Mach tick → ns conversion via `Sys.nanosPerTick` (Apple silicon: 125/3).
- `AppGrouper`: responsible pid → outermost `.app` → parent chain → "macOS"/tool.
- App layer: `Monitor` (live data + in-memory series) → observers → `AppServices` (history, alerts, projects, accessories, startup/storage state).
- `ImageRenderer` on XDR Macs produces 16-bit PQ HDR images; always redraw into 8-bit sRGB before saving PNGs (see `ShareCard.pngData`).

## Rules
- Anything that kills processes, runs launchctl or moves files must go through a confirmation dialog.
- Never delete files permanently; cleanup uses `FileManager.trashItem`.
- `.delegate/` holds prompts/outputs of delegated work (git-ignored).
