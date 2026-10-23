import SwiftUI
import TroveCore

/// Settings → AI → Activity and costs (its own window on the Mac): every request your AI made, on
/// every device, including background reading of handwriting, with its tokens and cost; totals for
/// a session, day, week or month, and what each kind of work spent. A lazy list, so a month of
/// requests doesn't have to be laid out at once (all of it at once pegged the processor).
struct AIActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var period: AIUsage.Period = .day
    @State private var deviceNames: [String: String] = [:]
    @State private var firstDay: String?

    /// Everything the screen shows, worked out once per change rather than in each row.
    private struct Summary {
        var calls: [AIUsage.Call] = []
        var total = AIUsage.Total()
        var parts: [(purpose: AIUsage.Purpose, total: AIUsage.Total)] = []
    }

    private func summary() -> Summary {
        let start = period.start(sessionStart: model.aiSessionStart)
        let me = model.config?.deviceId ?? ""
        let calls = model.aiCalls.filter { $0.at >= start && (period != .session || $0.device == me) }
        var byPurpose: [AIUsage.Purpose: AIUsage.Total] = [:]
        var total = AIUsage.Total()
        for c in calls {
            total.add(c)
            byPurpose[c.purpose, default: AIUsage.Total()].add(c)
        }
        let parts = AIUsage.Purpose.allCases.compactMap { p in byPurpose[p].map { (p, $0) } }
        return Summary(calls: calls, total: total, parts: parts)
    }

    var body: some View {
        let s = summary()
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(AIUsage.Period.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 12) {
                    stat(AIUsage.dollars(s.total.cost), "spent")
                    stat(AIUsage.tokens(s.total.tokens), "tokens")
                    stat("\(s.total.calls)", s.total.calls == 1 ? "request" : "requests")
                }
                if s.total.unpriced > 0 {
                    Text("\(s.total.unpriced) request\(s.total.unpriced == 1 ? "" : "s") from a provider that doesn't say its price: counted in tokens only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }

            if !s.parts.isEmpty || model.aiSettings.readHandwriting {
                Section("By kind of work") {
                    ForEach(s.parts, id: \.purpose) { part in
                        LabeledContent {
                            Text("\(AIUsage.dollars(part.total.cost)) · \(AIUsage.tokens(part.total.tokens)) tokens · \(part.total.calls)")
                                .monospacedDigit()
                        } label: {
                            Label(part.purpose.label, systemImage: Self.symbol(part.purpose))
                        }
                    }
                    if model.aiSettings.readHandwriting {
                        Text(limitLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Every request") {
                if s.calls.isEmpty {
                    Text("Nothing yet in this period.").foregroundStyle(.secondary)
                }
                ForEach(s.calls) { call in row(call) }
            }
        }
        #if os(macOS)
        .listStyle(.inset(alternatesRowBackgrounds: false))
        #endif
        .navigationTitle("AI activity")
        .task {
            await model.loadAIRecords()
            firstDay = await model.library?.firstAIUsageDay()
            if let devices = try? await model.vault.relayClient?.devices() {
                deviceNames = Dictionary(devices.map { ($0.deviceId.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    private func row(_ call: AIUsage.Call) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(call.purpose))
                .foregroundStyle(call.purpose.isBackground ? Color.orange : Brand.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.about.isEmpty ? call.purpose.label : "\(call.purpose.label): \(call.about)")
                    .lineLimit(2)
                Text("\(call.at.formatted(date: .abbreviated, time: .shortened)) · \(device(call.device)) · \(AIModelName.pretty(call.model))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(detail(call))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(call.cost.map(AIUsage.dollars) ?? "—").monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var limitLine: String {
        let spent = model.backgroundAISpend, limit = model.aiSettings.monthlyLimit
        guard limit > 0 else { return "Reading handwriting this month: \(AIUsage.dollars(spent)), no limit." }
        return spent >= limit
            ? "Reading handwriting has reached this month's limit (\(AIUsage.dollars(limit))) and is paused until next month; Apple's text recognition reads new pages meanwhile."
            : "Reading handwriting this month: \(AIUsage.dollars(spent)) of \(AIUsage.dollars(limit))."
    }

    /// Why this can read lower than the provider's console.
    private var footer: String {
        var parts = ["“This session” is this device since Trove opened; the others add up every device, using Claude's list prices."]
        if let firstDay, let date = AIUsage.dayFormatter.date(from: firstDay) {
            parts.append("Counting began on \(date.formatted(date: .abbreviated, time: .omitted)): anything your key spent before then, on a device still on an older Trove, or in other apps isn't here.")
        }
        parts.append("Anthropic's console counts days in UTC, so “Today” can differ by a few hours. Your provider's bill is the final word.")
        return parts.joined(separator: " ")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func device(_ id: String) -> String {
        if id == model.config?.deviceId { return "This device" }
        return deviceNames[id.uppercased()] ?? "Another device"
    }

    private func detail(_ c: AIUsage.Call) -> String {
        var parts = ["\(AIUsage.tokens(c.input)) in", "\(AIUsage.tokens(c.output)) out"]
        if c.cacheRead > 0 { parts.append("\(AIUsage.tokens(c.cacheRead)) cached") }
        if c.cacheWrite > 0 { parts.append("\(AIUsage.tokens(c.cacheWrite)) to cache") }
        return parts.joined(separator: " · ")
    }

    static func symbol(_ p: AIUsage.Purpose) -> String {
        switch p {
        case .ask: "bubble.left.and.text.bubble.right"
        case .handwriting: "pencil.and.scribble"
        case .action: "wand.and.stars"
        case .test: "checkmark.seal"
        case .keywords: "tag"
        }
    }
}
