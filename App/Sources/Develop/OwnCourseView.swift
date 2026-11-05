import SwiftUI
import TroveCore

/// Your own courses (learn-pivot plan §C1): anything outside the boards' catalogue, with topics you name.
extension DevelopModel {
    func makeOwnCourse(_ name: String, topics: [String]) async -> Course? {
        guard let library = app?.library, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let course = await library.makeOwnCourse(name, topics: topics)
        courses = await library.courses()
        await loadOwnTopics()
        return course
    }

    func addTopic(_ name: String, to course: Course) async {
        guard let library = app?.library else { return }
        await library.addTopic(name, to: course)
        await loadOwnTopics()
    }

    func removeTopic(_ topic: Concept, from course: Course) async {
        guard let library = app?.library else { return }
        await library.removeTopic(topic.id, from: course)
        await loadOwnTopics()
    }

    /// Every own course's topics, kept so screens don't read the vault in `body`.
    func loadOwnTopics() async {
        guard let library = app?.library else { return }
        var out: [String: [Concept]] = [:]
        for c in courses where c.isOwn { out[c.spec] = await library.topics(of: c) }
        ownTopics = out
    }

    /// A question you typed (C2.4): kept as a note in the course's folder, practised like an upload, marked by you.
    func addTypedQuestion(_ question: String, answer: String, marks: Int, topic: Concept, course: Course) async {
        guard let library = app?.library else { return }
        let body = answer.isEmpty ? question : "\(question)\n\n**Answer:** \(answer)"
        let note = await library.addNote(title: "Question: \(question.prefix(60))", body: body, folder: ["Learn", course.name, topic.name])
        await library.addProblem(sourceKey: "item:\(note)", key: "1", pages: [], marks: marks, level: .other,
                                 label: "\(course.name): \(topic.name)", skills: [topic.id], splitBy: "user")
        typedQuestions[note] = (question, answer)
        await app?.reload()
        await reload()
    }

    /// Practises your own course: its topics' problems, mixed (Practice.pick).
    func practise(_ course: Course) {
        let topics = Set((ownTopics[course.spec] ?? []).map(\.id))
        var filter = Practice.Filter()
        filter.orSkills = topics
        let seed = UInt64.random(in: 1...UInt64.max)
        let picked = Practice.pick(Practice.smallSession, from: practisable, attempts: attempts, skills: skills, filter: filter,
                                   now: Date().timeIntervalSince1970 * 1000, seed: seed)
        session = picked.isEmpty ? nil : Session(problems: picked, seed: seed)
        if picked.isEmpty { message = "Add a question to a topic first, then practise it here." }
    }
}

/// Making your own course: a name and its topics, one per line.
struct OwnCourseSheet: View {
    let develop: DevelopModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topics = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What are you learning?", text: $name, prompt: Text("Japanese for a trip in March"))
                } footer: {
                    Text("A university module, a language, an instrument, a certificate, anything.")
                }
                Section {
                    TextEditor(text: $topics).frame(minHeight: 140)
                } header: {
                    Text("Topics, one per line")
                } footer: {
                    Text("For example: Greetings, Numbers, Ordering food. You can add more later.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Your own course")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make it") {
                        working = true
                        let list = topics.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        Task {
                            _ = await develop.makeOwnCourse(name, topics: list)
                            working = false
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 440)
        #endif
    }
}

/// An own course's screen: its topics, each with Add a question and New note, and Practise.
struct OwnCourseView: View {
    @Environment(AppModel.self) private var model
    let develop: DevelopModel
    let course: Course
    @State private var newTopic = ""
    @State private var asking: Concept?

    var body: some View {
        let topics = develop.ownTopics[course.spec] ?? []
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.m) {
                        SubjectBadge(subject: course.name, size: 52)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(course.name).font(.title3.weight(.semibold))
                            Text("Your own course · \(topics.count) topic\(topics.count == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        develop.practise(course)
                        model.openLearn()
                    } label: { Label("Practise", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(topics.isEmpty)
                    if let message = develop.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            Section("Topics") {
                if topics.isEmpty {
                    Text("Add the topics you want to learn, then questions and notes for each.").foregroundStyle(.secondary)
                }
                ForEach(topics) { topic in
                    OwnTopicRow(topic: topic, ask: { asking = topic }, note: {
                        Task {
                            let id = await model.library?.addNote(title: topic.name, body: "", folder: ["Learn", course.name, topic.name])
                            if let id, let library = model.library {
                                _ = await library.setEdge(from: id, to: topic.id, type: .about, state: .accepted, origin: .user)
                                await model.reload()
                                model.selectedItemID = id
                            }
                        }
                    })
                    .swipeActions { Button("Remove", role: .destructive) { Task { await develop.removeTopic(topic, from: course) } } }
                }
                HStack {
                    TextField("New topic", text: $newTopic)
                        .onSubmit(addTopic)
                    Button("Add", action: addTopic).disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle(course.name)
        .task { await develop.loadOwnTopics() }
        .sheet(item: $asking) { topic in TypedQuestionSheet(develop: develop, course: course, topic: topic) }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Remove course", systemImage: "minus.circle", role: .destructive) { Task { await develop.removeCourse(course) } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func addTopic() {
        let name = newTopic
        newTopic = ""
        Task { await develop.addTopic(name, to: course) }
    }
}

private struct OwnTopicRow: View {
    let topic: Concept
    let ask: () -> Void
    let note: () -> Void

    var body: some View {
        HStack {
            Text(topic.name)
            Spacer()
            Button(action: ask) { Image(systemName: "questionmark.square.dashed") }
                .accessibilityLabel("Add a question to \(topic.name)")
                .help("Add a question")
            Button(action: note) { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New note for \(topic.name)")
                .help("New note for this topic")
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
    }
}

/// Typing a question with its answer (plan §C2.4): practised and marked by you.
private struct TypedQuestionSheet: View {
    let develop: DevelopModel
    let course: Course
    let topic: Concept
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""
    @State private var marks = 1

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") { TextEditor(text: $question).frame(minHeight: 90) }
                Section("Answer or mark points") { TextEditor(text: $answer).frame(minHeight: 90) }
                Section { Stepper("\(marks) mark\(marks == 1 ? "" : "s")", value: $marks, in: 1...20) }
            }
            .formStyle(.grouped)
            .navigationTitle(topic.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await develop.addTypedQuestion(question, answer: answer, marks: marks, topic: topic, course: course)
                            dismiss()
                        }
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }
}

/// A course in your list that this build's catalogue doesn't have (a newer catalogue, or a course made on a newer
/// build): said plainly instead of a spinner (review R2).
struct NotInCatalogueView: View {
    let course: Course

    var body: some View {
        EmptyState(symbol: "questionmark.folder", title: "Not in the catalogue",
                   message: "\(course.name) isn't in this device's list of courses yet. Update Trove on this device, or check again tomorrow when the list refreshes.")
    }
}
