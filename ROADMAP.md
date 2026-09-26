# Roadmap

## Done
**v0.1 (24.09.2026)** — processes grouped by app; per-app CPU/memory/GPU/disk/network/energy; menu bar; CPU per core, memory, disk, network, GPU, battery, temperatures, fans; 30-day history; alerts; dev servers by project; quit/force quit; share card; per-app volume (beta); "Why is my Mac slow?"; startup items; storage by app; `aplus` CLI.

**v0.2 (25.09.2026)**
- Developer ID signing, notarization, Sparkle auto-updates
- Menu bar builder: any number of items, 11 styles, colors, labels, auto-hide, clock with time zones; panel tabs for Battery and Projects; quit from the panel
- Settings with tabs: units (°C/°F, bytes/bits), accent color, sidebar pages, Overview card order
- From Stats: CPU cluster clocks, GPU clock and power, every drive with SMART/NVMe health, full sensor list, network interfaces/Wi-Fi/router, public IP on request
- Process inspector, connections per app, sleep & battery drain, weekly report, automations, unusual-activity and memory-leak detection, freeze detection (beta)
- `aplus mcp`: read-only MCP server for AI agents

**v0.2.1–0.2.3 (25.09.2026)**
- Menu bar quick menu (modules, presets, symbols), dark screenshots, background mode that renders nothing while hidden (about 1.4 % CPU)
- Uninstall with leftovers, large and old files, disk speed test, panel editor with tiles and themes
- Privileged helper (SMAppService daemon + XPC, read-only) built and notarized
- Safety and accuracy fixes after an independent code review (0.2.3)

**v0.2.4 (26.09.2026)**
- Recording sessions with compare and CSV/JSON export; performance/efficiency cores and IPC per app; Neural Engine memory per app
- Connection quality (latency, jitter, loss; off by default); displays with held-back refresh warning; power adapter and drain-while-plugged-in alert
- Menu bar, Dock or both; settings export and import

**v0.2.5 (26.09.2026)**
- The history traces spikes to child processes (busiest processes per app, redacted command lines); alerts and sessions name the process; MCP `history` answers "what was busy around …"

## Next
- [ ] Universal build (arm64 + x86_64) so Intel Macs can run it
- [ ] Privileged helper: test in daily use (exact disk, energy and memory figures of root processes)
- [ ] Test per-app volume, freeze detection and accessory batteries in daily use
- [ ] CPU power: find a documented source (IOReport's CPU energy channels read 0 on macOS 27)
- [ ] Menu bar item for any single sensor from the sensor list
- [ ] Homebrew cask
- [ ] German localization of the app
- [ ] Widgets (WidgetKit) and a Raycast extension on top of `aplus --json`
- [ ] Remote view: optional local web dashboard (`aplus serve`)
