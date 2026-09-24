# Activity+

A system monitor for macOS that answers the question Activity Monitor leaves open: **which app is responsible, and what should I do about it?**

Activity+ folds ~800 processes into ~80 apps, keeps 30 days of history, warns you when an app misbehaves, and lives in the menu bar. Everything stays on your Mac: no account, no analytics, no network requests.

## What it does

**Live monitoring**
- **Processes grouped by app.** Chrome's 96 helpers become one Chrome row. It uses the same "responsible process" information macOS uses for permission prompts, so `node` started in Terminal counts toward Terminal and MCP servers count toward Claude.
- **Per-app CPU, memory, GPU, disk, network and energy.** Energy is measured in watts by the kernel's per-task energy counters, not an "energy impact" score.
- **Per-app GPU time.** Read from the Metal driver's per-client counters. Activity Monitor and Vitals don't show this.
- **CPU per core** (efficiency and performance cores), memory pressure, swap, compression, disk and network throughput.
- **Temperatures and fans** for CPU, GPU and battery; fan RPM against each fan's min/max.
- **Battery:** health, charge cycles, whole-Mac power draw, time remaining, plus AirPods, Magic Mouse/Keyboard/Trackpad and game-controller batteries.

**Menu bar**
- Show an icon, a figure, a mini graph or two stacked figures (CPU, memory, GPU, network, temperature or battery).
- The item turns into a warning sign while the Mac is under strain (critical memory pressure, overheating, CPU pinned).
- Click for a compact dashboard with a tab per metric and the busiest apps. "Open Activity+" opens the main window on the same tab.

**History and alerts**
- **30 days of history** in one small SQLite file (about 10 MB). Covers the last 12 h, 24 h, 7 days or 30 days, which apps used the most, and data written/downloaded today and this week.
- **Alerts** when an app keeps the CPU busy, keeps growing in memory, or hammers the disk or network. System alerts cover memory running out, a nearly full disk, overheating and low accessory batteries. Thresholds are adjustable, you can ignore individual apps, and there is a cooldown so nothing nags.

**For developers**
- **Projects:** dev servers grouped by project folder, with their ports (click a port to open it), memory, uptime and whether they are working, idle or barely used. Stop a forgotten server with one confirmed click.

**Beyond Vitals**
- **Why is my Mac slow?** A one-click diagnosis in plain words: not enough memory, a runaway app, thermal throttling, nearly full disk, Spotlight indexing, idle dev servers, long uptime with heavy swap, worn battery. Each finding shows its evidence and offers a fix.
- **Startup items:** every LaunchAgent and LaunchDaemon, grouped by the app it belongs to, with running state. Agents in your account can be turned off and on; for system-wide items it copies the admin command.
- **Storage by app:** how much space each app takes including everything it keeps in `~/Library`, plus developer caches (npm, pnpm, Cargo, pip, Homebrew, Xcode). Caches and logs can be moved to the Trash; app data and settings are never touched.
- **Per-app volume** through Core Audio process taps (beta).
- **Share card:** a 1200 × 630 image of memory, top apps and CPU in light or dark, or copy the whole dashboard.
- **`aplus` CLI:** the same data in the terminal, with `--json` for scripts.

Quitting apps, force quitting, stopping servers, turning off startup items and moving files to the Trash always ask first.

## Build and run

Requires macOS 15 or later, Apple silicon or Intel, and Xcode 26 or later (the build uses `/Applications/Xcode-beta.app` by default; set `DEVELOPER_DIR` to use another Xcode).

```bash
scripts/build-app.sh --run      # release build → dist/Activity+.app, then launch
swift test                      # unit tests (parsers, grouping, alert and diagnosis rules, history)
.build/debug/aplus --memory     # terminal view, sorted by memory
```

## How it gets its numbers

| Figure | Source |
|---|---|
| Process list, CPU time of system processes | `/bin/ps` (setuid, sees every process without a helper) |
| Memory footprint, disk I/O, energy of your processes | `proc_pid_rusage` (`RUSAGE_INFO_V6`) |
| App grouping | `responsibility_get_pid_responsible_for_pid`, then bundle paths, then the parent chain |
| CPU per core, memory, swap, pressure | `host_processor_info`, `host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level` |
| Disk throughput | IOKit `IOBlockStorageDriver` statistics |
| Network (64-bit counters) | `sysctl NET_RT_IFLIST2`; per app via `nettop` |
| GPU and per-app GPU time | IOKit `IOAccelerator` performance statistics and per-client `AppUsage` |
| Temperatures, fans | IOHIDEventSystem sensors (Apple silicon), AppleSMC |
| Battery | `AppleSmartBattery`, `IOPSGetTimeRemainingEstimate`; accessories via IORegistry and `system_profiler` |
| Dev servers | `lsof` for listening sockets, process working directories |

Processes owned by other users (root, `_windowserver`) get CPU time and resident memory from `ps` but no disk or energy figures; the UI marks them "limited details". A privileged helper would close this gap (see the roadmap).

## Layout

```
Sources/ActivityCore   samplers, grouping, history, alerts, diagnosis, scanners (no UI; used by app and CLI)
Sources/ActivityPlus   SwiftUI app: main window, menu bar, settings
Sources/aplus          command-line tool
Tests/                 Swift Testing unit tests
scripts/build-app.sh   builds and ad-hoc signs dist/Activity+.app
```

## Privacy

Activity+ makes no network requests. History lives in `~/Library/Application Support/Activity+/history.sqlite` and alerts in `alerts.json` next to it; delete the folder to remove everything.
