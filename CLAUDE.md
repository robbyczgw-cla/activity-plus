# Activity+ — project notes

macOS system monitor (Vitals alternative + extras). SwiftPM, no Xcode project. Personal use first.

## Build, test, verify
- Toolchain: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (the default CLT has an old SDK). `scripts/build-app.sh` sets it.
- `scripts/build-app.sh --run` → `dist/Activity+.app` (ad-hoc signed) and launch.
- `swift test` — Swift Testing, pure logic in ActivityCore.
- **Visual check without screen-recording permission:** `ACTIVITYPLUS_SNAPSHOTS=/tmp/shots [ACTIVITYPLUS_PAGES=overview,metric:cpu,…] [ACTIVITYPLUS_WARMUP=12] dist/Activity+.app/Contents/MacOS/ActivityPlus` renders every page, the menu bar panel and both share cards to PNG, then quits. `screencapture` does not work from the agent shell.
- `.build/debug/aplus [--memory|--json|--bench|--hardware [--verbose]]` to sanity-check numbers, per-sampler timings, and IOReport/network/sensor readers. `aplus mcp` runs the MCP server.

## Architecture
- `ActivityCore/SystemSampler` builds one `SystemSnapshot` per tick from the samplers; all samplers keep previous counters, so call only from one serial queue (`Monitor`).
- Process list comes from `/bin/ps` (setuid) so root processes are visible; `proc_pid_rusage` refines own processes. Mach tick → ns conversion via `Sys.nanosPerTick` (Apple silicon: 125/3).
- `AppGrouper`: responsible pid → outermost `.app` → parent chain → "macOS"/tool.
- App layer: `Monitor` (live data + in-memory series) → observers → `AppServices` (history, alerts, projects, accessories, startup/storage state).
- `ImageRenderer` on XDR Macs produces 16-bit PQ HDR images; always redraw into 8-bit sRGB before saving PNGs (see `ShareCard.pngData`).

## Release
- `scripts/release.sh` signs with "Developer ID Application: Robert Czesany (P35939S43T)" (hardened runtime, `Resources/ActivityPlus.entitlements`), notarizes with the keychain profile `activityplus` (App Store Connect API key "hifiteam"), staples. `--publish` also builds the Sparkle appcast (EdDSA key in the login keychain, account `activityplus`) and creates the GitHub release on robbyczgw-cla/activity-plus with `docs/release-notes/v<version>.md`.
- Bump `CFBundleShortVersionString` in `Resources/Info.plist` before a release; the build number is the commit count.

## Gotchas
- Delegated agents (Codex) run in a sandbox that blocks IOKit/SystemConfiguration: their "returns nil" findings for hardware readers are not conclusive — test with `aplus --hardware` outside the sandbox.
- IOReport on M1 Max / macOS 27: GPU energy and all performance states work; CPU energy channels read 0. Frequencies come from `pmgr` `voltage-states1-sram` (E), `voltage-states5-sram` (P), `voltage-states9` (GPU).
- Leak detection only counts windows with a stable process count (`apps.procs`), otherwise new sessions/tabs look like leaks.
- README screenshots: never use pages that show project names, IPs or connections (public repo).

## Rules
- Anything that kills processes, runs launchctl or moves files must go through a confirmation dialog.
- Never delete files permanently; cleanup uses `FileManager.trashItem`.
- `.delegate/` holds prompts/outputs of delegated work (git-ignored).
