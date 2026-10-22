import SwiftUI
import TroveCore

/// Settings → AI → Activity and costs: every request your AI made, on every device, including
/// background reading of handwriting, with its tokens and cost; totals for a session, day, week or
/// month, and what each kind of work spent.
struct AIActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var period: AIUsage.Period = .day
    @State private var deviceNames: [String: String] = [:]

    private var calls: [AIUsage.Call] {
        let start = period.start(sessionStart: model.aiSessionStart)
        let me = model.config?.deviceId ?? ""
        return model.aiCalls.filter { $0.at >= start && (period != .session || $0.device == me) }
    }

    var body: some View {
        let total = AIUsage.Total(calls)
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(AIUsage.Period.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    stat(AIUsage.dollars(total.cost), "spent")
                    stat(AIUsage.tokens(total.tokens), "tokens")
                    stat("\(total.calls)", total.calls == 1 ? "request" : "requests")
                }
                if total.unpriced > 0 {
                    Text("\(total.unpriced) request\(total.unpriced == 1 ? "" : "s") from a provider that doesn't say its price: counted in tokens only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                FormFooter("“This session” is this device since Trove opened; the others add up every device. Prices are Claude's list prices; your provider's bill is the final word.")
            }

            Section("By kind of work") {
                ForEach(AIUsage.Purpose.allCases, id: \.self) { purpose in
                    let part = AIUsage.Total(calls.filter { $0.purpose == purpose })
                    if part.calls > 0 {
                        LabeledContent {
                            Text("\(AIUsage.dollars(part.cost)) · \(AIUsage.tokens(part.tokens)) tokens · \(part.calls)")
                                .monospacedDigit()
                        } label: {
                            Label(purpose.label, systemImage: Self.symbol(purpose))
                        }
                    }
                }
                if model.aiSettings.readHandwriting {
                    let spent = model.backgroundAISpend, limit = model.aiSettings.monthlyLimit
                    Text(limit > 0
                         ? (spent >= limit
                            ? "Reading handwriting has reached this month's limit (\(AIUsage.dollars(limit))) and is paused until next month; Apple's text recognition reads new pages meanwhile."
                            : "Reading handwriting this month: \(AIUsage.dollars(spent)) of \(AIUsage.dollars(limit)).")
                         : "Reading handwriting this month: \(AIUsage.dollars(spent)), no limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Every request") {
                if calls.isEmpty {
                    Text("Nothing yet in this period.").foregroundStyle(.secondary)
                }
                ForEach(calls.prefix(400)) { call in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Self.symbol(call.purpose))
                            .foregroundStyle(call.purpose.isBackground ? Color.orange : Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.about.isEmpty ? call.purpose.label : "\(call.purpose.label): \(call.about)")
                                .lineLimit(2)
                            Text("\(call.at.formatted(date: .abbreviated, time: .shortened)) · \(device(call.device)) · \(call.model)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(detail(call))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(call.cost.map(AIUsage.dollars) ?? "—").monospacedDigit()
                    }
                }
                if calls.count > 400 {
                    Text("Showing the newest 400 of \(calls.count).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI activity")
        .task {
            await model.loadAIRecords()
            if let devices = try? await model.vault.relayClient?.devices() {
                deviceNames = Dictionary(devices.map { ($0.deviceId.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
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
        }
    }
}
