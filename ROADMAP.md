# Roadmap

## Done (milestones 1–3, 24.09.2026)
- Processes grouped by app, per-app CPU / memory / GPU / disk / network / energy
- Menu bar item (icon, figure, graph, stacked, warning state) and compact panel
- CPU per core, memory breakdown, disk, network, GPU, battery, temperatures, fans, accessory batteries
- 30-day history (SQLite), today and 7-day totals, top apps per period
- Alerts with thresholds, cooldown, ignore list; system alerts
- Dev servers and ports by project, idle detection, stop with confirmation
- Quit / force quit apps and processes with confirmation
- Share card export (light/dark), copy dashboard
- Per-app volume (Core Audio taps, beta)
- Extras: "Why is my Mac slow?" diagnosis, startup items, storage by app with safe cleanup
- `aplus` CLI with JSON output

## Next
- [ ] **Test per-app volume on real audio** (needs the audio-capture permission prompt confirmed once)
- [ ] **Privileged helper** (SMAppService daemon) for exact disk, energy and footprint numbers of root processes
- [ ] App icon, Sparkle updates, Developer ID signing and notarization (needed before giving it to anyone else)
- [ ] Login items (BTM database) next to launch agents on the Startup page
- [ ] History for temperatures and per-app GPU
- [ ] Widgets (WidgetKit) and a Raycast extension on top of `aplus --json`
- [ ] Localization (German)
