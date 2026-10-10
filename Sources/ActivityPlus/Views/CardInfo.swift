import SwiftUI

/// Longer explanations behind the ⓘ next to a card title. `CardHeader` looks its title up here, so a card gets an
/// explanation by adding one line, without touching the view.
enum CardInfo {
    static func text(for title: String) -> String? { texts[title] }

    private static let texts: [String: String] = [
        // Storage
        "See what takes the space": String(localized: "Activity+ reads your home folder once and keeps a map of it. Sizes are the space files really use on disk, so files that live only in iCloud count as zero. Nothing is moved or removed unless you choose it and confirm."),
        "Map": String(localized: "Each tile is a folder or file; the bigger the tile, the more space it takes. Colors show the kind of files that fill most of it. Click a folder to go inside, use the path at the top to go back."),
        "Largest items": String(localized: "The biggest folders and files in the folder you are looking at, largest first. Right-click an item to show it in Finder or move it to the Trash."),
        "Biggest files": String(localized: "Searches the map of your home folder. Type words from a file name or use filters like ext:dmg, size:>1gb or opened:>1y; the ⓘ in the search field lists them all."),
        "What is in System Data": String(localized: "Settings → Storage shows one grey bar called System Data. These are its parts: developer data, caches, logs and things macOS manages itself. This tab only measures; removing happens in Clean up, after you confirm."),
        "Clean up": String(localized: "Everything here can go to the Trash. Safe items are rebuilt by the app that made them and are ticked; items to look at first are not. Caches of apps that are open are left alone, because the app would recreate them right away. Space is only freed when you empty the Trash."),
        "Space you can't see in Finder": String(localized: "Snapshots are copies macOS keeps for Time Machine and updates; purgeable space is what macOS frees by itself when something needs room. Neither shows in Finder. Activity+ explains them and links to the right setting, but never deletes snapshots."),
        "What wears your SSD": String(localized: "SSDs can only be written a certain amount over their life. The drive reports how much of that it has used; from your recent daily writes Activity+ estimates how many years are left, and which apps wrote the most."),
        "Drives": String(localized: "Every drive that is connected, with its connection and speed. A USB drive that could do USB 3 but runs at USB 2 speed is marked; the cable is the usual cause."),
        "Speed test": String(localized: "Writes and reads a test file large enough to get past the cache, so the result is the drive's real speed. The file is removed afterwards."),
        // Why is it slow, sleep, energy
        "Slower than it could be": String(localized: "Things that make the Mac slower right now, each with the evidence and what helps. Nothing changes until you click a button, and anything that quits an app asks first."),
        "Unusual activity": String(localized: "Apps that use clearly more than usual for them, compared with their own history, for example a helper stuck at full CPU."),
        "Waiting for your OK": String(localized: "Automations that found something to do and wait for you to allow it, for example quitting an idle dev server."),
        "Keeping your Mac awake right now": String(localized: "Apps and system services that currently prevent sleep (power assertions). A video call or a download can be a good reason; a forgotten one keeps the battery draining."),
        "Sleep and wake": String(localized: "When the Mac slept and woke, and what woke it: the lid, a key, the network, a timer or a connected device. Many short wakes at night drain the battery."),
        "Battery use while unplugged": String(localized: "Which apps used the most energy while the Mac ran on battery. Energy combines CPU, GPU and other parts, so it can differ from CPU alone."),
        "Needed a lot more energy than the week before": String(localized: "Apps whose energy use rose sharply compared with the previous week, often after an update or a stuck background task."),
        "What keeps WindowServer busy": String(localized: "WindowServer draws everything on screen, so its GPU load is really the load of the apps whose windows it draws. Find the Cause hides one app at a time for a few seconds, measures the difference and shows each app again."),
        "Conditions": String(localized: "Heat, memory pressure and Wi‑Fi quality on the same timeline as the history chart, so a slow moment lines up with what was going on."),
        "Thermal state": String(localized: "How hot the Mac runs by macOS's own measure. In serious or critical state macOS slows the chip down to cool it, so everything feels slower."),
        "Fans": String(localized: "Fan speed in revolutions per minute. Many Apple silicon Macs keep the fans off until they are needed."),
        // Hardware and resources
        "Memory": String(localized: "Used memory is not bad in itself; macOS fills free memory with caches. Memory pressure matters: when it turns yellow or red, macOS compresses and swaps to disk and the Mac slows down."),
        "Performance and efficiency cores": String(localized: "Apple silicon has fast performance cores and frugal efficiency cores. macOS puts background work on the efficiency cores; full performance cores mean something demanding is running."),
        "Neural Engine": String(localized: "The part of the chip for machine learning, used for things like dictation, photo analysis and on-device AI. Not every Mac reports its power."),
        "Health": String(localized: "Battery health is the capacity the battery holds now compared with when it was new. Below about 80 percent Apple considers the battery worn."),
        "Power flow": String(localized: "Where the power goes right now: from the adapter to the Mac and into the battery, or from the battery to the Mac."),
        "Connection quality": String(localized: "Regular pings to your router and an internet address show delay and lost packets over time; a problem only with the router points to Wi‑Fi, one only with the internet address points to your provider."),
        "Busiest right now": String(localized: "Processes grouped into the apps they belong to, so 40 helper processes of a browser show as one line. Click the arrow to see the processes inside."),
        "Recorded sessions": String(localized: "A recording measures the whole Mac every second while you run something heavy, like a build or an export. It does not film the screen. Compare two recordings or export them as CSV or JSON."),
    ]
}

/// A small ⓘ that shows a longer explanation when the pointer rests on it (or on click).
struct InfoButton: View {
    let text: String
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    // A short pause, so moving across the card doesn't flash the popover.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if hovering { shown = true } }
                } else {
                    shown = false
                }
            }
            .onTapGesture { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
                    .padding(14)
            }
            .accessibilityLabel(Text("More information"))
            .accessibilityHint(Text(text))
    }
}
