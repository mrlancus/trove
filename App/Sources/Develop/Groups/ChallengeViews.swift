import SwiftUI
import TroveCore

/// Pick catalogue questions for a challenge: a paper from your courses, then all of it (a mock) or some questions.
/// Only catalogue questions can be shared (their ids); each friend's device downloads the paper from the board.
struct NewChallengeSheet: View {
    let membership: GroupMembership
    @State private var groups = GroupsModel.shared
    @State private var paper: String?
    @State private var picked: Set<String> = []
    @State private var title = ""
    @State private var live = false
    @State private var deadline = Date().addingTimeInterval(3 * 86_400)
    @State private var minutes = 30
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Paper") {
                    Picker("Paper", selection: $paper) {
                        Text("Choose…").tag(String?.none)
                        ForEach(papers, id: \.id) { p in Text(p.label).tag(Optional(p.id)) }
                    }
                    if papers.isEmpty {
                        Text("Download some papers in your courses first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if paper != nil {
                    ChallengeQuestionPicker(questions: questions, picked: $picked)
                    Section("How") {
                        TextField("Title", text: $title)
                        Picker("Mode", selection: $live) {
                            Text("By a date").tag(false)
                            Text("Live, together").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if live {
                            Stepper("\(minutes) minutes", value: $minutes, in: 5...180, step: 5)
                        } else {
                            DatePicker("Hand in by", selection: $deadline, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                }
            }
            .navigationTitle("New challenge")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await send() } } label: { BusyLabel("Send", busy: groups.working) }
                        .disabled(chosen.isEmpty || groups.working)
                }
            }
            .onChange(of: paper) { _, new in
                picked = Set(questions.map(\.key))
                title = papers.first { $0.id == new }?.label ?? ""
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private struct Paper { var id: String; var label: String }

    /// Question papers on this device, newest first.
    private var papers: [Paper] {
        let develop = DevelopModel.shared
        return develop.courseSpecs.flatMap { spec in
            spec.questionPapers.filter { develop.cached.contains($0.id) }.map { doc in
                Paper(id: doc.id, label: develop.catalogue?.label(doc, in: spec, question: "").replacingOccurrences(of: " Q", with: "") ?? doc.id)
            }
        }.sorted { $0.id > $1.id }
    }

    private var questions: [Problem] {
        guard let paper else { return [] }
        return DevelopModel.shared.problems.filter { $0.sourceKey == "cat:\(paper)" }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private var chosen: [Problem] { questions.filter { picked.contains($0.key) } }

    private func send() async {
        guard let paper else { return }
        let c = StudyGroup.Challenge(title: title.isEmpty ? "Challenge" : String(title.prefix(80)),
                                     questions: chosen.map { .init(doc: paper, key: $0.key, marks: $0.marks) },
                                     mode: live ? .live : .deadline, deadline: live ? nil : deadline, minutes: live ? minutes : nil)
        await groups.newChallenge(membership, c)
        if groups.message == nil { dismiss() }
    }
}

private struct ChallengeQuestionPicker: View {
    let questions: [Problem]
    @Binding var picked: Set<String>

    var body: some View {
        Section {
            ForEach(questions) { q in
                Toggle(isOn: Binding(get: { picked.contains(q.key) }, set: { on in if on { picked.insert(q.key) } else { picked.remove(q.key) } })) {
                    Text("Question \(q.key)" + (q.marks.map { " · \($0) mark\($0 == 1 ? "" : "s")" } ?? ""))
                }
            }
        } header: {
            HStack {
                Text("Questions (\(picked.count) of \(questions.count))")
                Spacer()
                Button(picked.count == questions.count ? "None" : "Whole paper") {
                    picked = picked.count == questions.count ? [] : Set(questions.map(\.key))
                }
                .font(.caption)
            }
        }
    }
}

/// One challenge: do it, hand in, then everyone's answers and marks question by question.
struct ChallengeScreen: View {
    let groupId: String
    let challengeId: String
    @State private var groups = GroupsModel.shared
    @State private var develop = DevelopModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let m, let s, let c {
                    ChallengeHeader(challenge: c, state: s)
                    if s.submitted(c.id) {
                        ChallengeTotals(challenge: c, state: s)
                        ChallengeResults(membership: m, challenge: c, state: s)
                    } else {
                        ChallengeToDo(membership: m, challenge: c, state: s)
                    }
                    if let message = groups.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                } else {
                    EmptyState(symbol: "questionmark.circle", title: "Not here any more", message: "It may have been deleted.")
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: Theme.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(c?.title ?? "Challenge")
        .refreshable { await groups.refresh(groupId) }
    }

    private var m: GroupMembership? { groups.memberships.first { $0.groupId == groupId } }
    private var s: GroupState? { groups.states[groupId] }
    private var c: StudyGroup.Challenge? { s?.challenges.first { $0.id == challengeId } }
}

private struct ChallengeHeader: View {
    let challenge: StudyGroup.Challenge
    let state: GroupState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(challenge.title).font(.title2.weight(.bold))
            Text(line).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var line: String {
        let marks = challenge.questions.compactMap(\.marks).reduce(0, +)
        var parts = ["\(challenge.questions.count) question\(challenge.questions.count == 1 ? "" : "s")"]
        if marks > 0 { parts.append("\(marks) marks") }
        switch challenge.mode {
        case .live: parts.append("live, \(challenge.minutes ?? 30) minutes")
        case .deadline: if let d = challenge.deadline { parts.append("hand in by \(d.formatted(.dateTime.weekday().day().month().hour().minute()))") }
        }
        return parts.joined(separator: " · ")
    }
}

/// Before handing in: get the paper, start (live: together), and hand in. Nobody's answers show until then.
private struct ChallengeToDo: View {
    let membership: GroupMembership
    let challenge: StudyGroup.Challenge
    let state: GroupState
    @State private var groups = GroupsModel.shared
    @State private var develop = DevelopModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            let waiting = state.waiting[challenge.id] ?? 0
            Label(waiting == 0 ? "Nobody has handed in yet." : "\(waiting) handed in. You'll see their answers after you hand in yours.",
                  systemImage: "eye.slash").font(.callout).foregroundStyle(.secondary)
            if !groups.missingCourses(challenge).isEmpty {
                Text("This challenge uses a course you haven't added (\(groups.missingCourses(challenge).joined(separator: ", "))). Add it in Learn → Your courses, then come back.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if !groups.missingPapers(challenge).isEmpty {
                Button { groups.download(challenge) } label: { Label("Download the paper from the board", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else if develop.challengeRun?.challenge.id == challenge.id {
                let done = develop.challengeRun?.answers.count ?? 0
                Text("\(done) of \(challenge.questions.count) done.").font(.callout)
                HStack(spacing: Theme.Space.s) {
                    Button { Task { await groups.submit() } } label: { BusyLabel("Hand in", busy: groups.working) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Carry on") { groups.begin(membership, challenge) }.buttonStyle(.bordered).controlSize(.large)
                }
            } else {
                LiveOrStart(membership: membership, challenge: challenge, state: state)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }
}

private struct LiveOrStart: View {
    let membership: GroupMembership
    let challenge: StudyGroup.Challenge
    let state: GroupState
    @State private var groups = GroupsModel.shared

    var body: some View {
        if challenge.mode == .live {
            if let at = state.starts[challenge.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date < at {
                        Label { Text("Starts in ") + Text(at, style: .relative) } icon: { Image(systemName: "timer") }.font(.title3.weight(.semibold))
                    } else {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("Started: \(challenge.minutes ?? 30) minutes, ending \(at.addingTimeInterval(Double((challenge.minutes ?? 30) * 60)).formatted(date: .omitted, time: .shortened)).")
                                .font(.callout)
                            Button { groups.begin(membership, challenge) } label: { Label("Go", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }
                }
            } else {
                Text("Everyone starts together. Keep this open; when someone taps Start, it begins for everyone with the group open.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await groups.startLive(membership, challenge) } } label: { Label("Start for everyone in 10 seconds", systemImage: "timer") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        } else {
            Button { groups.begin(membership, challenge) } label: { Label("Start", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

/// A simple total each: marks over the marks of the marked answers. No ranking across challenges.
private struct ChallengeTotals: View {
    let challenge: StudyGroup.Challenge
    let state: GroupState

    var body: some View {
        let subs = (state.submissions[challenge.id] ?? [:]).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Handed in").font(.title3.weight(.semibold))
            ForEach(subs, id: \.key) { pair in
                let t = StudyGroup.total(pair.value)
                HStack {
                    Text(state.name(of: pair.key)).lineLimit(1)
                    Spacer()
                    Text(t.of > 0 ? "\(marksText(t.marks)) / \(t.of)" : "not marked yet").monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(minHeight: 32)
            }
        }
    }
}

private func marksText(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }

private struct ChallengeResults: View {
    let membership: GroupMembership
    let challenge: StudyGroup.Challenge
    let state: GroupState

    var body: some View {
        let results = state.results(challenge) ?? [:]
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ForEach(challenge.questions, id: \.self) { q in
                QuestionResults(membership: membership, challenge: challenge, question: q, results: results[q] ?? [], state: state)
            }
        }
    }
}

private struct QuestionResults: View {
    let membership: GroupMembership
    let challenge: StudyGroup.Challenge
    let question: StudyGroup.Question
    let results: [StudyGroup.Result]
    let state: GroupState
    @State private var marking: StudyGroup.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Question \(question.key)" + (question.marks.map { " · \($0) marks" } ?? "")).font(.headline)
            ForEach(results, id: \.member) { r in
                ResultRow(result: r, state: state, mine: r.member == membership.memberId, mark: { marking = r })
            }
            if results.isEmpty { Text("Nobody answered this one.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
        .sheet(item: Binding(get: { marking.map(MarkTarget.init) }, set: { if $0 == nil { marking = nil } })) { t in
            PeerMarkSheet(membership: membership, challenge: challenge, question: question, result: t.result, name: state.name(of: t.result.member))
        }
    }
}

private struct MarkTarget: Identifiable {
    let result: StudyGroup.Result
    var id: String { result.member }
}

private struct ResultRow: View {
    let result: StudyGroup.Result
    let state: GroupState
    let mine: Bool
    let mark: () -> Void
    @State private var groups = GroupsModel.shared
    @State private var accepted: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.name(of: result.member)).font(.body.weight(.semibold))
                Spacer()
                Text(result.answer.marks.map { "\(marksText($0)) / \(result.answer.of ?? 0)" } ?? "not marked").monospacedDigit()
            }
            Text(details).font(.caption).foregroundStyle(.secondary)
            if let text = result.answer.text, !text.isEmpty {
                Text(text).font(.callout).lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(result.peerMarks.sorted { $0.key < $1.key }, id: \.key) { pair in
                let by = pair.key, m = pair.value
                HStack {
                    Text("Marked by \(state.name(of: by)): \(marksText(m.marks)) / \(m.of)" + (m.note.map { ". \($0)" } ?? ""))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if mine {
                        Button(accepted.contains(by) ? "Accepted" : "Accept") { Task { await groups.accept(m); accepted.insert(by) } }
                            .buttonStyle(.bordered).controlSize(.small).disabled(accepted.contains(by))
                    }
                }
            }
            if !mine, result.answer.text?.isEmpty == false {
                Button("Mark this answer", action: mark).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private var details: String {
        let how: String = switch result.answer.marking {
        case .self: "self-marked against the mark scheme"
        case .ai: "marked by AI"
        case .peer: "marked by a friend"
        case .none: "not marked"
        }
        let time = result.answer.seconds >= 60 ? "\(result.answer.seconds / 60) min" : "\(result.answer.seconds) s"
        let hints = result.answer.hints == 0 ? "no hints" : "\(result.answer.hints) hint\(result.answer.hints == 1 ? "" : "s")"
        return "\(how) · \(time) · \(hints)"
    }
}

/// Peer marking: the friend's answer and the board's mark scheme, then the marks. They see your answer, never your files.
private struct PeerMarkSheet: View {
    let membership: GroupMembership
    let challenge: StudyGroup.Challenge
    let question: StudyGroup.Question
    let result: StudyGroup.Result
    let name: String
    @State private var groups = GroupsModel.shared
    @State private var marks = 0.0
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("\(name)'s answer") { Text(result.answer.text ?? "").textSelection(.enabled) }
                Section("Mark scheme") {
                    Text(scheme ?? "The mark scheme for this question isn't on this device yet; download the paper first.")
                        .font(.callout).foregroundStyle(scheme == nil ? .secondary : .primary).textSelection(.enabled)
                }
                Section("Your marks") {
                    Stepper("\(marksText(marks)) of \(of)", value: $marks, in: 0...Double(of), step: 1)
                    TextField("A note (optional)", text: $note, axis: .vertical).lineLimit(1...4)
                }
            }
            .navigationTitle("Mark Q\(question.key)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await send() } } label: { BusyLabel("Send", busy: groups.working) }.disabled(groups.working)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private var of: Int { result.answer.of ?? question.marks ?? 1 }

    private var scheme: String? {
        let develop = DevelopModel.shared
        return develop.problems.first { $0.sourceKey == "cat:\(question.doc)" && $0.key == question.key }.flatMap { develop.scheme(of: $0) }
    }

    private func send() async {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        await groups.mark(membership, .init(challenge: challenge.id, member: result.member, doc: question.doc, key: question.key,
                                            marks: marks, of: of, note: n.isEmpty ? nil : String(n.prefix(300))))
        if groups.message == nil { dismiss() }
    }
}
