import ActivityCore
import AppKit
import SwiftUI

/// WindowServer draws every window, so GPU work of most apps is booked to it. This card measures
/// which app is really behind that load by hiding apps one at a time.
struct GPUCauseCard: View {
    private var finder = GPUCauseFinder.shared
    @State private var confirming = false
    @State private var candidates: [GPUCauseFinder.Candidate] = []

    var body: some View {
        Card {
            CardHeader(title: "What keeps WindowServer busy", systemImage: "scope", tint: .purple)
            switch finder.state {
            case .idle:
                intro
            case let .running(step, total, label):
                running(step: step, total: total, label: label)
            case let .done(result, date, unmeasured):
                results(result, date: date, unmeasured: unmeasured)
            case let .failed(message):
                Text(message).foregroundStyle(.secondary)
                startButton(String(localized: "Try Again"))
            }
        }
        .alert("Hide apps for a moment?", isPresented: $confirming) {
            Button("Start") { finder.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(candidates.count) apps with open windows are hidden one after another and shown again, "
                + "then all together. This takes about \(GPUCauseFinder.estimatedSeconds(apps: candidates.count)) seconds. "
                + String(localized: "Leave the Mac alone meanwhile, or the measurement gets noisy."))
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "WindowServer puts every window on screen together. Apps that draw through it, which is most of them, ")
                + String(localized: "do not show their GPU use under their own name: it is counted as WindowServer."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("To find the app behind it, Activity+ hides your apps one at a time for a few seconds and measures how much WindowServer's GPU time drops.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            startButton(String(localized: "Find the Cause"))
        }
    }

    private func startButton(_ title: String) -> some View {
        Button(title) {
            candidates = GPUCauseFinder.candidates()
            confirming = true
        }
    }

    private func running(step: Int, total: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(step), total: Double(total))
            HStack {
                Text("\(label)…").monospacedDigit()
                Spacer()
                Text("\(step) of \(total)").foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel") { finder.cancel() }
            }
        }
    }

    private func results(_ result: GPUCauseAnalysis, date: Date, unmeasured: [String]) -> some View {
        let measurable = result.causes.filter(\.isMeasurable)
        let scale = max(result.baseline, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("WindowServer used \(Format.percent(result.baseline)) of the GPU with every window visible.")
            if measurable.isEmpty {
                Text(String(localized: "Hiding a single app made no measurable difference. ")
                    + String(localized: "The load comes from the displays themselves or from several apps together."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(measurable) { cause in
                row(name: cause.name, icon: icon(cause.bundleID), drop: cause.contribution, scale: scale,
                    detail: cause.quieterAfterShown
                        ? "\(Format.percent(cause.hiddenPercent)) while hidden, and it stayed quiet after being shown again: it was redrawing constantly until it was hidden"
                        : "\(Format.percent(cause.hiddenPercent)) while hidden")
            }
            if let floor = result.floor {
                if unmeasured.isEmpty {
                    row(name: "Displays, desktop and menu bar", icon: Image(systemName: "display"), drop: floor, scale: scale,
                        detail: "left with all apps hidden", isRemainder: true)
                } else {
                    row(name: "Left with the measured apps hidden", icon: Image(systemName: "display"), drop: floor, scale: scale,
                        detail: { let names = unmeasured.joined(separator: ", "); return String(localized: "still visible and not measured: \(names)") }(), isRemainder: true)
                }
            }
            let quiet = result.causes.filter { !$0.isMeasurable }.map(\.name)
            if !quiet.isEmpty {
                Text("No measurable effect: \(quiet.joined(separator: ", ")).")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            if result.noise >= 3 {
                Text("WindowServer's load wandered by about \(Format.percent(result.noise)) points on its own during the run, so smaller drops are not named.")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Measured \(date.formatted(date: .omitted, time: .shortened))").appFont(.caption).foregroundStyle(.secondary)
                Spacer()
                startButton(String(localized: "Measure Again"))
            }
        }
    }

    private func row(name: String, icon: Image, drop: Double, scale: Double, detail: String, isRemainder: Bool = false) -> some View {
        HStack(spacing: 10) {
            icon.resizable().scaledToFit().frame(width: 22, height: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name).fontWeight(isRemainder ? .regular : .medium)
                    Spacer()
                    Text(isRemainder ? Format.percent(drop) : "−\(Format.percent(drop))").monospacedDigit()
                }
                UsageBar(fraction: min(1, drop / scale), tint: isRemainder ? .gray : .purple)
                Text(LocalizedStringKey(detail)).appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ bundleID: String?) -> Image {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Image(systemName: "app")
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
