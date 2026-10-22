import SwiftUI
import TroveCore

/// Ask Trove: a chat with your AI about everything you've saved. It looks things up itself (an
/// overview, searches, then only the items it needs), shows each step and what it's costing as it
/// goes, and keeps every chat (History). Without your AI it falls back to Apple Intelligence or the
/// relay, one question at a time.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var chat: AIChat?
    /// The question being answered and how far it's got.
    @State private var pending: String?
    @State private var progress = AIClient.Progress()
    @State private var tier: AISettings.Tier = .fast
    @State private var showHistory = false
    /// Without your AI: the last answer from Apple Intelligence or the relay.
    @State private var fallback: (answer: String, sources: [Item], by: String)?
    @AppStorage("askUsagePeriod") private var periodRaw = AIUsage.Period.day.rawValue
    @FocusState private var focused: Bool

    private var period: AIUsage.Period { AIUsage.Period(rawValue: periodRaw) ?? .day }
    private var ownAI: Bool { model.aiSettings.isReady }
    private var turns: [AIChat.Turn] { chat?.turns ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 22) {
                            if turns.isEmpty && pending == nil && fallback == nil {
                                AskWelcome { idea in
                                    // "Find my notes about…" waits for you to finish it.
                                    if idea.hasSuffix("…") { question = String(idea.dropLast()) + " "; focused = true } else { question = idea; ask() }
                                }
                                    .padding(.top, 40)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                            ForEach(Array(turns.enumerated()), id: \.offset) { i, turn in
                                AskTurnView(turn: turn, open: open)
                                    .id(i)
                                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
                            }
                            if let fallback {
                                AskTurnView(turn: AIChat.Turn(question: question, answer: fallback.answer, sources: fallback.sources.map(\.id), model: fallback.by), open: open)
                            }
                            if let pending {
                                AskWorking(question: pending, progress: progress)
                                    .id("pending")
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                        .frame(maxWidth: 680)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: turns.count) { withAnimation(.smooth) { proxy.scrollTo(turns.count - 1, anchor: .bottom) } }
                    .onChange(of: progress.steps.count) { withAnimation(.smooth) { proxy.scrollTo("pending", anchor: .bottom) } }
                }
                composer
            }
            .background(AskBackground().ignoresSafeArea())
            .navigationTitle(chat.map { $0.displayTitle } ?? "Ask Trove")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if ownAI {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showHistory = true } label: { Label("Chats", systemImage: "clock.arrow.circlepath") }
                            .help("Your chats")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                            .disabled(turns.isEmpty || pending != nil)
                            .help("New chat")
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                AskHistory(current: chat?.id) { picked in
                    withAnimation(.smooth) { chat = picked; fallback = nil }
                }
            }
        }
        .sheetSize(width: 780, height: 680)
        .onAppear { focused = true }
    }

    // MARK: Composer and costs

    private var composer: some View {
        VStack(spacing: 8) {
            if ownAI { usagePill }
            HStack(alignment: .bottom, spacing: 10) {
                if ownAI {
                    Menu {
                        Picker("Model", selection: $tier) {
                            ForEach(AISettings.Tier.allCases, id: \.self) { t in
                                Text("\(t.label) · \(model.aiSettings.model(t))").tag(t)
                            }
                        }
                    } label: {
                        Label(tier.label, systemImage: tier == .fast ? "hare" : tier == .smart ? "brain" : "sparkles")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Fast is cheapest; Smarter and Best think harder and cost more")
                }
                TextField(turns.isEmpty ? "Ask anything about what you've saved…" : "Ask a follow-up…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(ask)
                    .padding(.vertical, 6)
                Button(action: ask) {
                    Image(systemName: pending == nil ? "arrow.up" : "ellipsis")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray.opacity(0.4))))
                        .symbolEffect(.pulse, isActive: pending != nil)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glass(cornerRadius: 26)
            if !ownAI {
                Text(model.aiStatus + " Add your own AI in Settings → AI for chats that search everything.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
    }

    /// What your AI has cost: tap for this session, today, this week or this month.
    private var usagePill: some View {
        let total = model.aiTotal(period)
        return Button {
            let all = AIUsage.Period.allCases
            withAnimation(.snappy) { periodRaw = all[((all.firstIndex(of: period) ?? 0) + 1) % all.count].rawValue }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(period.label).fontWeight(.semibold)
                Text("·")
                Text(AIUsage.tokens(total.tokens) + " tokens").contentTransition(.numericText())
                Text("·")
                Text(AIUsage.dollars(total.cost)).monospacedDigit().contentTransition(.numericText())
                if total.unpriced > 0 { Text("+ unpriced").foregroundStyle(.tertiary) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Tap to switch between this session, today, this week and this month. Everything is listed in Settings → AI → Activity and costs.")
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty && pending == nil }

    // MARK: Actions

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, pending == nil else { return }
        if !ownAI {
            Task {
                withAnimation(.smooth) { pending = q }
                let result = await model.ask(q, tier: tier)
                withAnimation(.smooth) { fallback = result; pending = nil }
            }
            return
        }
        question = ""
        progress = AIClient.Progress()
        withAnimation(.smooth) { pending = q }
        let current = chat
        Task {
            let updated = await model.askAI(q, in: current, tier: tier) { p in
                withAnimation(.snappy) { progress = p }
            }
            withAnimation(.smooth) {
                if let updated { chat = updated }
                pending = nil
            }
        }
    }

    private func newChat() {
        withAnimation(.smooth) { chat = nil; fallback = nil; question = "" }
        focused = true
    }

    private func open(_ id: String) {
        model.selectedItemID = id
        dismiss()
    }
}

/// The first screen: what you can ask.
private struct AskWelcome: View {
    let pick: (String) -> Void
    @State private var appeared = false

    private let ideas = [
        "What did I save this week?",
        "Find my notes about…",
        "Summarise everything I have on…",
        "What's in my Handwritten folder?",
    ]

    var body: some View {
        VStack(spacing: 18) {
            AskOrb(active: false).frame(width: 84, height: 84)
            VStack(spacing: 6) {
                Text("Ask your Trove").font(.title.weight(.semibold))
                Text("It searches everything you've saved and opens only what it needs.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(Array(ideas.enumerated()), id: \.offset) { i, idea in
                    Button { pick(idea) } label: {
                        Text(idea)
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 360)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
                    .animation(.smooth.delay(0.08 * Double(i) + 0.1), value: appeared)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

/// A slowly turning, glowing orb: Trove's AI (faster and brighter while it works).
struct AskOrb: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * (active ? 1.6 : 0.5)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [.pink, .purple, .blue, .teal, .pink], center: .center, angle: .radians(t)))
                    .blur(radius: active ? 14 : 10)
                    .opacity(active ? 0.9 : 0.6)
                    .scaleEffect(1 + (active ? 0.06 : 0.03) * sin(t * 2))
                Circle()
                    .fill(AngularGradient(colors: [.white.opacity(0.9), .pink.opacity(0.7), .blue.opacity(0.7), .white.opacity(0.9)], center: .center, angle: .radians(-t * 1.3)))
                    .padding(10)
                    .blur(radius: 2)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .purple.opacity(0.6), radius: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A faint coloured wash behind the chat.
private struct AskBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [.purple.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [.pink.opacity(0.08), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 520)
        }
    }
}

/// The question being answered: each step as it happens and the running cost.
private struct AskWorking: View {
    let question: String
    let progress: AIClient.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QuestionBubble(text: question)
            HStack(alignment: .top, spacing: 14) {
                AskOrb(active: true).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerText(text: progress.steps.isEmpty ? "Thinking…" : "Working…")
                    ForEach(Array(progress.steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: step.hasPrefix("Searched") ? "magnifyingglass" : step.hasPrefix("Opened") ? "doc.text" : step.hasPrefix("Browsed") ? "list.bullet" : "square.grid.2x2")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    if progress.usage.calls > 0 {
                        Text("\(AIUsage.tokens(progress.usage.tokens)) tokens · \(AIUsage.dollars(progress.usage.cost)) so far")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Text with a light sweeping across it.
private struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.5)
                        .offset(x: phase * g.size.width)
                        .blendMode(.plusLighter)
                }
                .mask(Text(text).font(.callout.weight(.semibold)))
            }
            .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 } }
    }
}

private struct QuestionBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// One question and its answer: the steps it took (folded), sources, model, tokens and cost.
private struct AskTurnView: View {
    @Environment(AppModel.self) private var model
    let turn: AIChat.Turn
    let open: (String) -> Void
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestionBubble(text: turn.question)
            VStack(alignment: .leading, spacing: 12) {
                Text(markdown(turn.answer))
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let items = turn.sources.compactMap { id in model.items.first { $0.id == id } }
                if !items.isEmpty {
                    FlowChips(items: items, open: open)
                }
                HStack(spacing: 8) {
                    if !turn.steps.isEmpty {
                        Button {
                            withAnimation(.snappy) { showSteps.toggle() }
                        } label: {
                            Label("\(turn.steps.count) step\(turn.steps.count == 1 ? "" : "s")", systemImage: showSteps ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.plain)
                    }
                    if !turn.model.isEmpty { Text(turn.model) }
                    if turn.tokens > 0 { Text("\(AIUsage.tokens(turn.tokens)) tokens") }
                    if let cost = turn.cost { Text(AIUsage.dollars(cost)).monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showSteps {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, s in Text("• " + s) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
            .padding(16)
            .background(.background.secondary.opacity(0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.35), lineWidth: 0.5))
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// The items an answer drew on, as chips that open them.
private struct FlowChips: View {
    let items: [Item]
    let open: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button { open(item.id) } label: {
                        Label(item.displayTitle, systemImage: ItemStyle.symbol(for: item))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.tint.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Every chat with your AI, newest first.
private struct AskHistory: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let current: String?
    let pick: (AIChat) -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.aiChats.isEmpty {
                    Text("No chats yet.").foregroundStyle(.secondary)
                }
                ForEach(model.aiChats) { chat in
                    Button {
                        pick(chat)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chat.displayTitle).lineLimit(1).fontWeight(chat.id == current ? .semibold : .regular)
                            Text("\(chat.turns.count) question\(chat.turns.count == 1 ? "" : "s") · \(chat.updatedAt.relative) · \(AIUsage.dollars(chat.cost))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", role: .destructive) { Task { await model.deleteAIChat(chat.id) } }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await model.deleteAIChat(chat.id) } }
                    }
                }
            }
            .navigationTitle("Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheetSize(width: 460, height: 520)
    }
}
