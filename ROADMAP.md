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

## Next
- [ ] **Privileged helper** (SMAppService daemon + XPC) for exact disk, energy and memory figures of root processes
- [ ] Test per-app volume, freeze detection and accessory batteries in daily use
- [ ] CPU power: find a documented source (IOReport's CPU energy channels read 0 on macOS 27)
- [ ] Menu bar item for any single sensor from the sensor list
- [ ] Homebrew cask
- [ ] German localization of the app
- [ ] Widgets (WidgetKit) and a Raycast extension on top of `aplus --json`
- [ ] Remote view: optional local web dashboard (`aplus serve`)
