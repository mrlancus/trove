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
        DiagnosticsSection()
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

/// Lag measured on this device (docs/PERF_AUDIT.md step 0): hangs over 100 ms, frames and hitches
/// during a measuring session, how long screens take to show their content; one file to export.
private struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    @State private var watching = Diagnostics.watchEnabled
    @State private var measuring = Diagnostics.shared.measuringFrames
    @State private var exported: URL?
    @State private var savedToVault = false
    @State private var error: String?

    var body: some View {
        let d = Diagnostics.shared
        let week = d.hangs.filter { $0.at > Date().addingTimeInterval(-7 * 86_400) }
        Section {
            Toggle("Watch for lag", isOn: $watching)
                .onChange(of: watching) { _, on in d.setWatching(on) }
            LabeledContent("Hangs over 100 ms, 7 days", value: week.isEmpty ? "None" : "\(week.count), worst \(Int(week.map(\.ms).max() ?? 0)) ms")
            ForEach(Self.worstWorkflows(week), id: \.0) { name, count in
                LabeledContent(name, value: "\(count)").font(.caption)
            }
            if let last = d.sessions.last {
                LabeledContent("Last frames session", value: "\(last.total.hitches) hitches in \(last.total.frames) frames, worst \(Int(last.total.worstMs)) ms")
            }
            ForEach(d.navigationSummary(), id: \.workflow) { row in
                LabeledContent("Open \(row.workflow)", value: "p50 \(Int(row.p50)) ms · p90 \(Int(row.p90)) ms (\(row.count))").font(.caption)
            }
            Button(measuring ? "Stop measuring frames" : "Measure frames for 10 minutes") {
                if measuring { d.stopFrames() } else { d.startFrames() }
                measuring = d.measuringFrames
            }
            Button("Export diagnostics") {
                do { exported = try d.exportFile() } catch { self.error = error.localizedDescription }
            }
            if let exported {
                ShareLink(item: exported) { Label(exported.lastPathComponent, systemImage: "square.and.arrow.up") }
                Button(savedToVault ? "Saved to your vault" : "Save a copy to the vault") {
                    Task { await saveToVault(exported) }
                }
                .disabled(savedToVault)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Lag and frames")
        } footer: {
            FormFooter("Watch for lag notes every time Trove's main thread is busy for over 100 ms while it's in front, and which screen you were on. Measuring frames counts dropped frames for up to 10 minutes; use it while you scroll, pan or write, then export. Everything stays on this device until you share or save it.")
        }
    }

    static func worstWorkflows(_ hangs: [Diagnostics.Hang]) -> [(String, Int)] {
        Dictionary(grouping: hangs, by: \.workflow).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(3).map { $0 }
    }

    func saveToVault(_ url: URL) async {
        guard let library = model.library, let data = try? Data(contentsOf: url) else { return }
        do {
            _ = try await library.addFile(data, name: url.lastPathComponent, mime: "application/json", kind: .file, source: .app,
                                          title: "Trove diagnostics \(Date().formatted(date: .abbreviated, time: .shortened))")
            savedToVault = true
        } catch { self.error = error.localizedDescription }
    }
}
