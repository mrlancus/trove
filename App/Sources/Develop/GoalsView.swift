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
                        Text(first.skills.isEmpty ? (goal.courses.isEmpty && develop.goalUploads(goal).isEmpty ? "From anything you've downloaded." : "From this goal's papers.")
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
    /// Editing a goal: what it is now; the chat changes it and `apply` gets the result (nothing is saved here).
    var editing: GoalChat.Proposal? = nil
    var apply: ((GoalChat.Proposal) -> Void)? = nil
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
                            bubble(.ai, editing == nil
                                   ? "What are you preparing for? Say it however you like: \"physics A-level next June\", \"BPhO round 1\", \"my chemistry mocks\"."
                                   : "What would you like to change? For example: \"move it to 12 June\", \"add my uploaded chemistry papers\", \"only Paper 2\", \"aim for an A*\".")
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
            .navigationTitle(editing == nil ? "New goal" : "Change this goal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if editing == nil {
                    ToolbarItem(placement: .primaryAction) { Button("Fill in myself") { form = true } }
                }
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
            if !p.uploads.isEmpty {
                let names = develop.uploadList.filter { p.uploads.contains($0.id) }.map(\.title)
                Label(names.joined(separator: ", "), systemImage: "doc.richtext").font(.subheadline).lineLimit(3)
            }
            if let t = p.target { Label("Aiming for \(t)", systemImage: "target").font(.subheadline) }
            if !p.summary.isEmpty { Text(p.summary).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(editing == nil ? "Add goal" : "Use these changes") {
                    if let apply {
                        apply(p)
                        dismiss()
                        return
                    }
                    Task {
                        await develop.saveGoal(.init(id: "campaign.\(UUID().uuidString)", name: p.name, deadline: GoalChat.deadline(p.date) ?? 0,
                                                     courses: p.courses, papers: p.papers, uploads: p.uploads, target: p.target, summary: p.summary))
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
                switch try await develop.clarifyGoal(messages, current: editing) {
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
    @State private var picked: Set<String> = []
    @State private var excluded: Set<String> = []
    /// Uploads matching the goal by name: worked out when the courses, name or notes change, not per row
    /// (it froze Edit goal before, reading every PDF's name for each row on each redraw).
    @State private var automatic: Set<String> = []
    @State private var chatting = false

    var body: some View {
        NavigationStack {
            Form {
                if develop.hasAI {
                    Section {
                        Button { chatting = true } label: {
                            Label(goal == nil ? "Talk it through with your AI" : "Change it by chatting with your AI", systemImage: "bubble.left.and.bubble.right")
                        }
                    } footer: { Text("Say what to change (the date, papers, your own papers, the target); you check it here before saving.") }
                }
                Section {
                    TextField("Goal (e.g. AQA A-level Physics)", text: $name)
                    DatePicker("Date", selection: $date, in: Date()..., displayedComponents: .date)
                }
                Section {
                    if develop.courses.isEmpty {
                        Text("Add courses in Learn to link them here.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(develop.courses) { c in
                        Toggle(isOn: Binding(get: { courses.contains(c.spec) }, set: { on in if on { courses.insert(c.spec) } else { courses.remove(c.spec) } })) {
                            Text(c.name)
                        }
                    }
                    // A course the chat added that isn't one of yours yet (saving adds it).
                    ForEach(courses.filter { id in !develop.courses.contains { $0.spec == id } }.sorted(), id: \.self) { id in
                        Toggle(isOn: Binding(get: { courses.contains(id) }, set: { on in if on { courses.insert(id) } else { courses.remove(id) } })) {
                            Text(develop.catalogue?.spec(id).map { "\(develop.boardName($0.board)) \($0.name)" } ?? id)
                        }
                    }
                } header: { Text("Courses") } footer: { Text("Practice for this goal comes from these courses' papers.") }
                uploadsSection
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
            .onAppear { load(); refreshMatches() }
            .onChange(of: courses) { _, _ in refreshMatches() }
            .onChange(of: name) { _, _ in refreshMatches() }
            .onChange(of: summary) { _, _ in refreshMatches() }
            .sheet(isPresented: $chatting) { GoalChatSheet(develop: develop, editing: current, apply: use) }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
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
        picked = Set(goal.uploads)
        excluded = Set(goal.excludedUploads)
    }

    // MARK: Your own papers

    private func refreshMatches() {
        automatic = develop.automaticUploads(courses: Array(courses), name: name, summary: summary)
    }

    private func isOn(_ id: String) -> Bool { picked.contains(id) || automatic.contains(id) && !excluded.contains(id) }

    private func turn(_ id: String, _ on: Bool) {
        if on {
            excluded.remove(id)
            if !automatic.contains(id) { picked.insert(id) }
        } else {
            picked.remove(id)
            if automatic.contains(id) { excluded.insert(id) }
        }
    }

    /// Your uploads: the ones in this goal or matching it first, then the rest of your practised ones;
    /// any other PDF in your trove from the menu; and Upload right here.
    private var uploadsSection: some View {
        let auto = automatic
        let on = Set(develop.myPDFs.map(\.id).filter(isOn))
        let practised = develop.practisedItems
        let shown = develop.myPDFs.filter { on.contains($0.id) || auto.contains($0.id) || practised.contains($0.id) }
            .sorted { (on.contains($0.id) ? 0 : 1, $0.displayTitle) < (on.contains($1.id) ? 0 : 1, $1.displayTitle) }
        let shownIds = Set(shown.map(\.id))
        let others = develop.myPDFs.filter { !shownIds.contains($0.id) }
        return Section {
            if shown.isEmpty {
                Text("None yet. Upload a paper here, or from a board's website, and it's added to this goal.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { item in
                Toggle(isOn: Binding(get: { isOn(item.id) }, set: { turn(item.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle).lineLimit(2)
                        if auto.contains(item.id) && !excluded.contains(item.id) && !picked.contains(item.id) {
                            Text("Matches this goal").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !others.isEmpty {
                Menu {
                    ForEach(others.prefix(60)) { item in Button(item.displayTitle) { turn(item.id, true) } }
                } label: { Label("Add a PDF from your trove…", systemImage: "doc.text.magnifyingglass") }
            }
            UploadMenu(develop: develop, added: { ids in for id in ids { turn(id, true) } }) {
                Label("Upload papers…", systemImage: "square.and.arrow.up")
            }
        } header: { Text("Your own papers") } footer: {
            Text("Uploads whose name matches this goal's course (or, without one, its name) join it automatically; turn off any you don't want.")
        }
    }

    // MARK: Chat

    /// The goal as it is in the form, for the chat to change.
    private var current: GoalChat.Proposal {
        let uploads = develop.uploadList.map(\.id).filter(isOn)
        return GoalChat.Proposal(name: name, date: DevelopModel.day(date), courses: Array(courses).sorted(),
                                 papers: papers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                 target: target.isEmpty ? nil : target, summary: summary, uploads: uploads)
    }

    /// What the chat settled on, into the form (you still Save).
    private func use(_ p: GoalChat.Proposal) {
        if !p.name.isEmpty { name = p.name }
        if let d = GoalChat.deadline(p.date) { date = Date(timeIntervalSince1970: d / 1000) }
        courses = Set(p.courses)
        papers = p.papers.joined(separator: ", ")
        target = p.target ?? ""
        summary = p.summary
        // Exactly the uploads it chose: picked, and any other automatic match turned off.
        refreshMatches()
        picked = Set(p.uploads)
        excluded = automatic.subtracting(p.uploads)
    }

    private func save() async {
        var g = goal ?? .init(id: "campaign.\(UUID().uuidString)", name: "", deadline: 0)
        g.name = name.trimmingCharacters(in: .whitespaces)
        g.deadline = date.timeIntervalSince1970 * 1000
        let mine = develop.courses.map(\.spec)
        g.courses = mine.filter(courses.contains) + courses.subtracting(mine).sorted()
        // Only what's needed: picks that aren't automatic, and automatic matches turned off.
        let auto = automatic
        g.uploads = picked.subtracting(auto).sorted()
        g.excludedUploads = excluded.intersection(auto).sorted()
        g.papers = papers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        g.target = target.trimmingCharacters(in: .whitespaces).isEmpty ? nil : target.trimmingCharacters(in: .whitespaces)
        g.summary = summary.trimmingCharacters(in: .whitespaces).isEmpty ? nil : summary
        await develop.saveGoal(g)
        dismiss()
        done?()
    }
}
