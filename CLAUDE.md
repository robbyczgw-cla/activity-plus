# Activity+ — project notes

macOS system monitor (Vitals alternative + extras). SwiftPM, no Xcode project. Personal use first.

## Build, test, verify
- Toolchain: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the default CLT has an old SDK). `scripts/build-app.sh` sets it.
- `scripts/build-app.sh --run` → `dist/Activity+.app` (ad-hoc signed) and launch.
- `swift test` — Swift Testing, pure logic in ActivityCore.
- **Visual check without screen-recording permission:** `ACTIVITYPLUS_SNAPSHOTS=/tmp/shots [ACTIVITYPLUS_PAGES=overview,metric:cpu,…] [ACTIVITYPLUS_WARMUP=12] dist/Activity+.app/Contents/MacOS/ActivityPlus` renders every page, the menu bar panel and both share cards to PNG, then quits. `screencapture` does not work from the agent shell. `ACTIVITYPLUS_WINDOW_SIZE=1080x1700` renders long pages in full. Afterwards check `pgrep -fl dist/Activity+.app`: a run that stops early can leave a dev copy running, and its menu bar items then appear twice next to the installed app.
- `.build/debug/aplus [--memory|--json|--bench|--hardware [--verbose]]` to sanity-check numbers, per-sampler timings, and IOReport/network/sensor readers. `aplus mcp` runs the MCP server.

## Localization
- English source strings in `Resources/Localizable.xcstrings`, translated into the languages listed in `Info.plist` `CFBundleLocalizations`; `build-app.sh` compiles them into the app's `<lang>.lproj`.
- `scripts/l10n-extract.sh` collects new strings (compiler extraction plus the literals passed to `CardHeader`, `StatLine`, `.help`, menu items); `--check` fails on untranslated ones and runs in `release.sh`. `scripts/l10n-apply.py <lang> file.json` writes translations, plurals as `{"one","other"}`; run `scripts/l10n-validate.py <lang> file.json` first (keys, placeholders, plural forms). A `%` followed by a space and a letter reads as a format specifier, so avoid it in translations.
- UI text in ActivityCore goes through `String(localized:)`; never localize identifiers, process names, pmset/IORegistry keys or dictionary keys. Count phrases use catalog plurals, not `? "" : "s"`.
- `Format.locale` stays nil for the CLI and MCP (machine-readable "25.7"); the app sets the user's locale.
- German follows macOS: "du", "Batterie" (not "Akku"), Activity Monitor's terms.

## Architecture
- `ActivityCore/SystemSampler` builds one `SystemSnapshot` per tick from the samplers; all samplers keep previous counters, so call only from one serial queue (`Monitor`).
- Process list comes from `/bin/ps` (setuid) so root processes are visible; `proc_pid_rusage` refines own processes. Mach tick → ns conversion via `Sys.nanosPerTick` (Apple silicon: 125/3).
- `AppGrouper`: responsible pid → outermost `.app` → parent chain → "macOS"/tool.
- App layer: `Monitor` (live data + in-memory series) → observers → `AppServices` (history, alerts, projects, accessories, startup/storage state).
- `ImageRenderer` on XDR Macs produces 16-bit PQ HDR images; always redraw into 8-bit sRGB before saving PNGs (see `ShareCard.pngData`).

## Release
- `scripts/release.sh` signs with "Developer ID Application: Robert Czesany (P35939S43T)" (hardened runtime, `Resources/ActivityPlus.entitlements`), notarizes with an App Store Connect API key stored as the keychain profile `activityplus`, staples. `--publish` also builds the Sparkle appcast (EdDSA key in the login keychain, account `activityplus`) and creates the GitHub release on robbyczgw-cla/activity-plus with `docs/release-notes/v<version>.md`. It also bumps the Homebrew cask in `../homebrew-tap` (github.com/robbyczgw-cla/homebrew-tap). `--site` updates the homepage; `--site --publish` does both with one build and one notarization.
- Bump `CFBundleShortVersionString` in `Resources/Info.plist` before a release; the build number is the commit count.

## Gotchas
- Delegated agents (Codex) run in a sandbox that blocks IOKit/SystemConfiguration: their "returns nil" findings for hardware readers are not conclusive — test with `aplus --hardware` outside the sandbox.
- IOReport on M1 Max / macOS 27: GPU energy and all performance states work; CPU, ANE and the per-block energy channels (GPU0, ISP0, AVE0, DRAM0) read 0, so UI shows those only when non-zero. Frequencies come from `pmgr` `voltage-states1-sram` (E), `voltage-states5-sram` (P), `voltage-states9` (GPU).
- Leak detection only counts windows with a stable process count (`apps.procs`), otherwise new sessions/tabs look like leaks.
- README screenshots: never use pages that show project names, IPs or connections (public repo).

## Rules
- Anything that kills processes, runs launchctl or moves files must go through a confirmation dialog.
- Never delete files permanently; cleanup uses `FileManager.trashItem`.
- `.delegate/` holds prompts/outputs of delegated work (git-ignored).
