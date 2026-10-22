import SwiftUI
import TroveCore

/// Settings → Battery (docs/ROADMAP.md §3.7): how hard Trove works on this device (not synced), what
/// it's doing right now, what the last sketch cost, and MetricKit's daily reports to share.
struct BatterySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var power = model.power
        Section {
            Picker("Battery use", selection: $power.mode) {
                Text("Automatic").tag(PowerState.Mode.automatic)
                Text("Save battery").tag(PowerState.Mode.saveBattery)
                Text("Full speed").tag(PowerState.Mode.fullSpeed)
            }
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                LabeledContent("Right now", value: Self.describe(model.policy))
            }
        } header: {
            Text("Battery")
        } footer: {
            FormFooter("Automatic follows Low Power Mode, the charger and heat. On battery, text recognition and AI do only what you saved on this device in the last hour; the rest happens overnight on the charger. While a sketch is open, changes go out after a pause or every few minutes instead of after every stroke. Save battery always works that way; Full speed works as if plugged in. Applies to this device only.")
        }
        Section("What it cost") {
            if let sketch = model.power.sketch {
                CountersView(title: "This sketch", counters: sketch)
            }
            if let last = model.power.lastSketch {
                CountersView(title: "Last sketch", counters: last)
            }
            CountersView(title: "Since Trove opened", counters: model.power.sinceLaunch)
        }
        BatteryReportSection()
    }

    static func describe(_ policy: PowerPolicy) -> String {
        let s = policy.state
        if policy.onlyOnClose { return "Very hot: syncing when the sketch closes" }
        if s.thermal >= .serious { return "Hot: background work paused" }
        if policy.unlimited { return s.charging ? "On the charger: full speed" : "Full speed" }
        if policy.saving { return s.lowPowerMode ? "Low Power Mode: saving battery" : "Saving battery" }
        return "On battery"
    }
}

private struct CountersView: View {
    let title: String
    let counters: PowerCounters

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(duration).foregroundStyle(.secondary).font(.caption)
            }
            Text(line1).font(.caption).foregroundStyle(.secondary)
            Text(line2).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var duration: String {
        let end = counters.ended ?? Date()
        let minutes = Int(max(0, end.timeIntervalSince(counters.started)) / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private var line1: String {
        let c = counters
        return "\(c.pushes) pushes · \(c.pulls) pulls · \(c.requests) requests · \(c.syncRounds) syncs · \(c.livePings) pings"
    }

    private var line2: String {
        let c = counters
        let kb = c.cacheBytes / 1024
        return "\(c.inkReloads) ink reloads · \(c.visionPages) pages read · \(c.aiCalls) AI calls · \(c.saves) saves · \(kb) KB caches"
    }
}

/// MetricKit's daily payloads (energy, CPU, wake-ups, disk writes; diagnostics for hangs and crashes).
private struct BatteryReportSection: View {
    @State private var reports: [URL] = []

    var body: some View {
        Section {
            if reports.isEmpty {
                Text("No report yet. iPadOS and iOS hand one over about once a day, starting a day after Trove first runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(reports.prefix(10), id: \.self) { url in
                ShareLink(item: url) {
                    Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                }
            }
        } header: {
            Text("Battery report")
        } footer: {
            FormFooter("Daily reports from the system about Trove's energy, CPU, wake-ups and disk writes. They stay on this device until you share one.")
        }
        .task { reports = MetricsReporter.reports() }
    }
}
