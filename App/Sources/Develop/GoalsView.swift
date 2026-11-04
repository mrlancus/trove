import SwiftUI
import TroveCore

/// Goals on Develop's home: each one's countdown, readiness, how long you have today, and today's plan.
struct GoalsCard: View {
    @Bindable var develop: DevelopModel
    @State private var adding = false
    @State private var editing: CampaignPlanner.Goal?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Goals").font(.headline)
                Spacer()
                Button { adding = true } label: { Label("New goal", systemImage: "flag") }.buttonStyle(.bordered).controlSize(.small)
            }
            if develop.goals.isEmpty {
                Button { adding = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "flag.checkered").font(.title2).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preparing for something?").font(.subheadline.weight(.semibold))
                            Text(develop.hasAI ? "Tell Trove in your own words; it asks until it's sure what you mean, then plans each day."
                                               : "Add the exam or competition and its date; Trove plans each day from what you've shown so far.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: Theme.Radius.medium))
                }
                .buttonStyle(.plain)
            }
            ForEach(develop.goals, id: \.id) { goal in
                GoalCard(develop: develop, goal: goal) { editing = goal }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
        .sheet(isPresented: $adding) {
            if develop.hasAI { GoalChatSheet(develop: develop) } else { GoalForm(develop: develop, goal: nil) }
        }
        .sheet(item: $editing) { goal in GoalForm(develop: develop, goal: goal) }
    }
}

struct GoalCard: View {
    let develop: DevelopModel
    let goal: CampaignPlanner.Goal
    let edit: () -> Void
    static let times = [15, 30, 45, 60, 90, 120]

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        let plan = develop.plan(goal)
        let today = (now / CampaignPlanner.day).rounded(.down) * CampaignPlanner.day
        let todaySet = goal.todayDate.map { abs($0 - today) < 1 } ?? false
        let subject = develop.catalogue?.spec(goal.courses.first ?? "")?.subject ?? goal.name
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ReadinessRing(value: plan.readiness, color: SubjectStyle.symbol(subject).color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.name).font(.headline)
                    Text(Date(timeIntervalSince1970: goal.deadline / 1000), format: .dateTime.weekday(.abbreviated).day().month(.wide).year())
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let summary = goal.summary, !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    let chips = goal.papers + (goal.target.map { ["Aiming for \($0)"] } ?? [])
                    if !chips.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(chips, id: \.self) { c in
                                Text(c).font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: .capsule)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Text("\(goal.daysLeft(now: now))").font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                    Text(goal.daysLeft(now: now) == 1 ? "day left" : "days left").font(.caption2).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(todaySet ? "Today you have" : "How long have you got today?").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.times, id: \.self) { m in
                            let on = todaySet && goal.todayMinutes == m
                            Button { Task { await develop.setToday(goal, minutes: m) } } label: {
                                Text(m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)")
                                    .font(.caption.weight(on ? .semibold : .regular))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(on ? Theme.accent : Color.secondary.opacity(0.12), in: .capsule)
                                    .foregroundStyle(on ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
            if let first = plan.days.first {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today: \(first.questions) question\(first.questions == 1 ? "" : "s")").font(.subheadline.weight(.semibold))
                        Text(first.skills.isEmpty ? (goal.courses.isEmpty ? "From anything you've downloaded." : "From this goal's papers.")
                             : first.skills.map(develop.name).joined(separator: ", ") + (first.diagnostic ? " (a first check)" : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Start") { develop.startGoal(goal) }.buttonStyle(.borderedProminent)
                }
            }
            if plan.total > 0 { Text(plan.why).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
        .contextMenu {
            Button("Edit goal", systemImage: "pencil", action: edit)
            Button("Remove goal", systemImage: "trash", role: .destructive) { Task { await develop.removeGoal(goal) } }
        }
        .onTapGesture(count: 2, perform: edit)
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Edit goal", systemImage: "pencil", action: edit)
                Button("Remove goal", systemImage: "trash", role: .destructive) { Task { await develop.removeGoal(goal) } }
            } label: { Image(systemName: "ellipsis").font(.caption.weight(.bold)).padding(8).contentShape(.rect) }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Goal options")
        }
    }
}

/// How much of the goal's skills you've shown, as a ring.
struct ReadinessRing: View {
    let value: Double
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 7)
            Circle().trim(from: 0, to: max(0.001, value)).stroke(color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(width: 54, height: 54)
        .accessibilityElement()
        .accessibilityLabel("Ready: \(Int((value * 100).rounded())) percent")
    }
}

/// Making a goal by talking it through: your AI asks until it's sure, then shows the goal to confirm.
struct GoalChatSheet: View {
    let develop: DevelopModel
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [GoalChat.Message] = []
    @State private var options: [String] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var proposal: GoalChat.Proposal?
    @State private var error: String?
    @State private var form = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            bubble(.ai, "What are you preparing for? Say it however you like: \"physics A-level next June\", \"BPhO round 1\", \"my chemistry mocks\".")
                            ForEach(Array(messages.enumerated()), id: \.offset) { _, m in bubble(m.role, m.text) }
                            if thinking { ProgressView().padding(.leading, 12) }
                            if let error { Text(error).font(.caption).foregroundStyle(.red) }
                            if let proposal { proposalCard(proposal) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _, _ in withAnimation { reader.scrollTo("end") } }
                    .onChange(of: proposal) { _, _ in withAnimation { reader.scrollTo("end") } }
                }
                if proposal == nil { composer }
            }
            .navigationTitle("New goal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Fill in myself") { form = true } }
            }
            .sheet(isPresented: $form) { GoalForm(develop: develop, goal: nil) { dismiss() } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func bubble(_ role: GoalChat.Message.Role, _ text: String) -> some View {
        HStack {
            if role == .you { Spacer(minLength: 40) }
            Text(text)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(role == .you ? Theme.accent : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 16))
                .foregroundStyle(role == .you ? .white : .primary)
            if role == .ai { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !options.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(options, id: \.self) { o in
                            Button(o) { send(o) }.buttonStyle(.bordered).controlSize(.small).disabled(thinking)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack {
                TextField("Your answer", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(input) }
                Button { send(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
                    .accessibilityLabel("Send")
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func proposalCard(_ p: GoalChat.Proposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.name).font(.headline)
            if let d = GoalChat.deadline(p.date) {
                Label(Date(timeIntervalSince1970: d / 1000).formatted(date: .long, time: .omitted), systemImage: "calendar").font(.subheadline)
            }
            if !p.courses.isEmpty {
                Label(p.courses.map { id in develop.catalogue?.spec(id).map { spec in "\(develop.boardName(spec.board)) \(spec.name)" } ?? id }.joined(separator: ", "),
                      systemImage: "graduationcap").font(.subheadline)
            }
            if !p.papers.isEmpty { Label(p.papers.joined(separator: ", "), systemImage: "doc.text").font(.subheadline) }
            if let t = p.target { Label("Aiming for \(t)", systemImage: "target").font(.subheadline) }
            if !p.summary.isEmpty { Text(p.summary).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Add goal") {
                    Task {
                        await develop.saveGoal(.init(id: "campaign.\(UUID().uuidString)", name: p.name, deadline: GoalChat.deadline(p.date) ?? 0,
                                                     courses: p.courses, papers: p.papers, target: p.target, summary: p.summary))
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Not quite") { proposal = nil; options = [] }.buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: Theme.Radius.medium))
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !thinking else { return }
        messages.append(.init(.you, t))
        input = ""
        options = []
        error = nil
        thinking = true
        Task {
            defer { thinking = false }
            do {
                switch try await develop.clarifyGoal(messages) {
                case .ask(let q, let opts):
                    messages.append(.init(.ai, q))
                    options = opts
                case .ready(let p):
                    proposal = p
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The goal by hand, and editing any goal: name, date, courses, papers, target. No minutes a day here:
/// the goal card asks how long you have each day.
struct GoalForm: View {
    let develop: DevelopModel
    let goal: CampaignPlanner.Goal?
    var done: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var date = Date().addingTimeInterval(30 * 86_400)
    @State private var courses: Set<String> = []
    @State private var papers = ""
    @State private var target = ""
    @State private var summary = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Goal (e.g. AQA A-level Physics)", text: $name)
                    DatePicker("Date", selection: $date, in: Date()..., displayedComponents: .date)
                }
                Section {
                    if develop.courses.isEmpty {
                        Text("Add courses on Develop's home to link them here.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(develop.courses) { c in
                        Toggle(isOn: Binding(get: { courses.contains(c.spec) }, set: { on in if on { courses.insert(c.spec) } else { courses.remove(c.spec) } })) {
                            Text(c.name)
                        }
                    }
                } header: { Text("Courses") } footer: { Text("Practice for this goal comes from these courses' papers.") }
                Section {
                    TextField("Papers (e.g. Paper 1, Paper 2)", text: $papers)
                    TextField("Target (e.g. A*, grade 7)", text: $target)
                    TextField("Notes", text: $summary, axis: .vertical)
                }
                if let goal {
                    Section {
                        Button("Remove goal", role: .destructive) { Task { await develop.removeGoal(goal); dismiss() } }
                    }
                }
            }
            .navigationTitle(goal == nil ? "New goal" : "Edit goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(goal == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func load() {
        guard let goal else { return }
        name = goal.name
        date = Date(timeIntervalSince1970: goal.deadline / 1000)
        courses = Set(goal.courses)
        papers = goal.papers.joined(separator: ", ")
        target = goal.target ?? ""
        summary = goal.summary ?? ""
    }

    private func save() async {
        var g = goal ?? .init(id: "campaign.\(UUID().uuidString)", name: "", deadline: 0)
        g.name = name.trimmingCharacters(in: .whitespaces)
        g.deadline = date.timeIntervalSince1970 * 1000
        g.courses = develop.courses.map(\.spec).filter(courses.contains)
        g.papers = papers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        g.target = target.trimmingCharacters(in: .whitespaces).isEmpty ? nil : target.trimmingCharacters(in: .whitespaces)
        g.summary = summary.trimmingCharacters(in: .whitespaces).isEmpty ? nil : summary
        await develop.saveGoal(g)
        dismiss()
        done?()
    }
}
