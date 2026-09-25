# Activity+

**A system monitor for macOS that tells you which app is responsible, and what to do about it.**

[Deutsch](README.de.md)

Activity Monitor lists about 800 processes. Activity+ folds them into about 80 apps, keeps 30 days of history, warns you when an app misbehaves, explains why your Mac is slow, and lives in your menu bar, looking exactly the way you want it to. Everything stays on your Mac.

![Overview](docs/screenshots/overview.png)

## Download

Get the latest notarized build from [Releases](https://github.com/robbyczgw-cla/activity-plus/releases/latest). Unzip it, move **Activity+.app** to Applications and open it. Updates arrive automatically once a day; you can turn that off in Settings.

Requires macOS 15 Sequoia or later. Developed and tested on Apple silicon (M1 Max); Intel Macs should work but are untested.

## What it does

### See which app is responsible
- **Processes grouped by app.** Chrome's helpers become one Chrome row. Activity+ uses the same "responsible process" information macOS uses for permission prompts, so `node` started in Terminal counts toward Terminal, and MCP servers count toward the app that launched them.
- **Per-app CPU, memory, GPU, disk, network and energy.** Energy is measured in watts by the kernel's per-task counters. GPU time per app comes from the Metal driver.
- **Process inspector.** Double-click a process to see its command line, working folder, who started it, who signed it (and whether it is notarized), open files and network connections.
- **Connections.** Which servers each app talks to right now. Host names are looked up only if you switch that on.

![CPU](docs/screenshots/metric-cpu.png)

### Hardware
- CPU per core (efficiency and performance), **clock speed per cluster**, load average, thermal state.
- Memory pressure, swap, compression.
- GPU load, clock and power.
- **Every drive** with free space, throughput, SMART status and NVMe wear, temperature, hours and data written.
- Network throughput, interfaces, addresses, Wi-Fi signal, channel and link speed. Your public IP is fetched only when you click for it.
- **All sensors**: several hundred temperatures, voltages, currents and power readings, plus fans.
- Battery health, charge cycles and power draw, plus AirPods, Magic Mouse, Keyboard and Trackpad batteries.

![Disk](docs/screenshots/metric-disk.png)

### A menu bar that looks the way you want
Add as many menu bar items as you like. Each shows one thing (CPU, memory, GPU, disk, network, temperature, fans, battery, power or a clock with time zones) in one of eleven styles: value, label and value, line chart, bar chart, bar per core, ring, gauge, dot, up/down speed, battery or icon. Colors can match the menu bar, go from green to red with the load, or use a color you pick. An item can hide itself until its value is high. Click an item for a compact panel on the matching tab; right-click for a menu.

![Menu bar styles](docs/screenshots/widgets-dark.png)

<p>
<img src="docs/screenshots/menubar-overview.png" width="360" alt="Menu bar panel">
<img src="docs/screenshots/settings-menuBar.png" width="480" alt="Menu bar settings">
</p>

The rest is adjustable too: which pages the sidebar shows, which Overview cards appear and in which order, the accent color, °C or °F, bytes or bits for network speeds, the refresh interval, and which tabs the menu bar panel has.

### Why is my Mac slow?
One click gives a plain-language verdict: not enough memory, an app running flat out, heat throttling, a nearly full disk, Spotlight indexing, idle dev servers, a long uptime with heavy swap, a worn battery. Each finding shows its evidence and offers the fix.

![Diagnosis](docs/screenshots/diagnosis.png)

### History, alerts and insights
- **30 days of history** in one small SQLite file: charts for 12 hours to 30 days, which apps used the most, data written and downloaded today and this week.
- **Alerts** when an app keeps the CPU busy, keeps growing in memory, or hammers the disk or network, and when memory runs out, the disk fills up, the Mac overheats or an app freezes.
- **Unusual for this app.** Activity+ learns what is normal for each app and tells you when it is far off ("Slack uses 3.2× its usual memory"). Steady growth with a stable set of processes is reported as a likely memory leak, with a forecast.
- **Weekly report** every Monday: the apps that used the most energy, memory, CPU and network, compared with the week before.
- **Sleep & battery drain.** What is keeping your Mac awake right now, what woke it up, and which apps drained the battery while it was unplugged.

### Let it take care of things
- **Automations**: "stop dev servers that have been idle for a day", "quit an app when it uses more than 4 GB". Each rule asks first with a notification button, unless you explicitly allow it to act on its own.
- **Dev servers by project**, with their ports and whether they are working, idle or barely used. Stop a forgotten one with one confirmed click.
- **Startup items** grouped by app, with switches for the ones in your account.
- **Storage by app**, including everything the app keeps in your Library, plus developer caches. Caches and logs can be moved to the Trash; app data is never touched.
- **Per-app volume** (beta), quit and force quit from any list, and a 1200 × 630 share card of your Mac's state.

Anything that quits a process, stops a server, changes a startup item or moves files asks first.

## For AI agents

`aplus mcp` is a read-only [Model Context Protocol](https://modelcontextprotocol.io) server with seven tools: overview, top apps, an app's processes, diagnosis, dev servers, history and startup items. With Claude Code:

```bash
claude mcp add activity-plus -- "/Applications/Activity+.app/Contents/Resources/aplus" mcp
```

Then ask "why is my Mac slow?" or "which dev server is idle?". The same binary prints a terminal view (`aplus`, `aplus --memory`) and JSON (`aplus --json`).

## Privacy

Activity+ has no account and no analytics. Its only automatic network request is the daily update check, which you can turn off. The public IP lookup and host-name lookups happen only when you ask for them. History lives in `~/Library/Application Support/Activity+/`; delete that folder to remove everything.

## How it measures

| Figure | Source |
|---|---|
| Process list; CPU of other users' processes | `/bin/ps` (sees every process without a privileged helper) |
| Memory footprint, disk I/O, energy of your processes | `proc_pid_rusage` |
| App grouping | responsible process, then app bundle paths, then the parent chain |
| CPU, memory, swap, pressure | `host_processor_info`, `host_statistics64`, `sysctl` |
| Clock speeds, GPU power | IOReport performance states and energy model |
| GPU load and per-app GPU time | IOKit `IOAccelerator` |
| Temperatures, voltages, currents, fans | IOHID event system and the SMC |
| Drives and NVMe health | IOKit block storage statistics and the NVMe SMART log |
| Network | `sysctl NET_RT_IFLIST2`, `nettop` per app, SystemConfiguration, CoreWLAN |
| Dev servers and connections | `lsof` |

Processes owned by other users (root, `_windowserver`) show CPU and resident memory but no disk or energy figures; they are marked "limited details".

## Build from source

Needs Xcode 26 or later. The scripts use `/Applications/Xcode-beta.app`; set `DEVELOPER_DIR` to use another Xcode.

```bash
scripts/build-app.sh --run      # debug-signed build in dist/, then launch
swift test                      # unit tests
scripts/release.sh              # Developer ID signing and notarization (needs credentials)
```

The code is split into `ActivityCore` (samplers, history, rules; no UI), the SwiftUI app `ActivityPlus`, and the `aplus` command-line tool.

## Status

Activity+ is young. Per-app volume, freeze detection and accessory batteries are beta: they are built and pass their checks, but have seen little real-world testing. See [ROADMAP.md](ROADMAP.md) for what is next.

Inspired by Activity Monitor, [Vitals](https://vitalsmac.com) and [Stats](https://mac-stats.com).
