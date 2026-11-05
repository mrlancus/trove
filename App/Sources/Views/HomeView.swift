import SwiftUI
import TroveCore

/// Home: where the app opens. Learning first (learn-pivot plan §4 B2): the next exam or goal, one small Up next
/// session with any due cards, three quiet numbers, what to continue, then your notes, sketches and pins.
/// Made of small views, each watching only what it shows.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var develop = DevelopModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HomeHeader(develop: develop)
                HomeUpNext(develop: develop)
                HomeNumbers(develop: develop)
                HomeContinue(develop: develop)
                HomeShelves()
                HomeMakeRow()
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await develop.start(model)
            Diagnostics.shared.ready("Home")
        }
        .perfWorkflow("Home")
    }

    static func hello(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

extension AppModel {
    /// Opens Learn: the sidebar's Learn on iPad and Mac, the Learn tab on iPhone (`learnRequests`).
    func openLearn() {
        selection = .develop
        learnRequests += 1
    }
}

/// The greeting and the next exam or goal date ("Physics paper 1 in 23 days").
private struct HomeHeader: View {
    let develop: DevelopModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(HomeView.hello(Date.now)).font(.largeTitle.weight(.bold))
            if let next = Self.nextGoal(develop.goals) {
                Label(next, systemImage: "calendar").font(.headline).foregroundStyle(Theme.accent)
            }
        }
    }

    /// The nearest goal still ahead: "Physics paper 1 in 23 days", "… tomorrow", "… today".
    static func nextGoal(_ goals: [CampaignPlanner.Goal], now: Date = .now) -> String? {
        let ms = now.timeIntervalSince1970 * 1000
        guard let g = goals.filter({ $0.deadline >= ms - 86_400_000 }).min(by: { $0.deadline < $1.deadline }) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                   to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: g.deadline / 1000))).day ?? 0
        return days <= 0 ? "\(g.name) today" : days == 1 ? "\(g.name) tomorrow" : "\(g.name) in \(days) days"
    }
}

/// Up next: always one small session (about 3 questions, ~10 min; plan §1.1), plus the cards that are due.
/// With nothing to practise yet, it says what to do instead.
private struct HomeUpNext: View {
    @Environment(AppModel.self) private var model
    let develop: DevelopModel
    @State private var dueCards = 0

    var body: some View {
        let ready = !develop.practisable.isEmpty
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if ready {
                Text(sessionLine).font(.title2.weight(.semibold))
                if let why = develop.next?.why { Text(why).font(.callout).foregroundStyle(.secondary) }
                HStack(spacing: Theme.Space.s) {
                    Button {
                        develop.startSession(count: Practice.smallSession, skill: develop.next?.skill.id)
                        if develop.session == nil { develop.startSession(count: Practice.smallSession) }
                        model.openLearn()
                    } label: { Label("Start", systemImage: "play.fill").frame(minWidth: 88) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if dueCards > 0 { cardsButton }
                }
            } else {
                Text(develop.courses.isEmpty ? "What are you learning?" : "Get your first questions").font(.title2.weight(.semibold))
                Text(develop.courses.isEmpty
                     ? "Pick an exam course or make your own, and Trove gives you small practice sessions from real papers."
                     : "Download a paper in your course and it's split into questions to practise.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.s) {
                    Button { model.openLearn() } label: { Label(develop.courses.isEmpty ? "Choose" : "Open Learn", systemImage: "graduationcap") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    if dueCards > 0 { cardsButton }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
        .task(id: model.dataVersion) {
            dueCards = await model.library?.studyQueue().count ?? 0
        }
    }

    /// "3 questions on Momentum, ~10 min".
    private var sessionLine: String {
        let n = min(Practice.smallSession, develop.practisable.count)
        let topic = develop.next.map { " on \($0.skill.name)" } ?? ""
        return "\(n) question\(n == 1 ? "" : "s")\(topic), ~\(max(5, n * 3 + 1)) min"
    }

    private var cardsButton: some View {
        Button {
            model.studyDeck = nil
            model.showStudy = true
        } label: { Label("\(dueCards) card\(dueCards == 1 ? "" : "s") due", systemImage: "rectangle.on.rectangle.angled") }
        .buttonStyle(.bordered).controlSize(.large)
    }
}

/// Three numbers: this week, days in a row (quiet: no flame, no warnings), recent average.
private struct HomeNumbers: View {
    let develop: DevelopModel

    var body: some View {
        let s = develop.stats
        if !develop.attempts.isEmpty {
            HStack(spacing: Theme.Space.m) {
                HomeStat(value: "\(s.thisWeek)", label: s.thisWeek == 1 ? "question this week" : "questions this week", symbol: "checkmark.circle")
                HomeStat(value: "\(s.streak)", label: s.streak == 1 ? "day in a row" : "days in a row", symbol: "calendar")
                HomeStat(value: s.recentAverage.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", label: "recent average", symbol: "chart.line.uptrend.xyaxis")
            }
        }
    }
}

private struct HomeStat: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Image(systemName: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: Theme.Radius.large)
    }
}

/// Continue: the last practice sketch, or the topic you last practised.
private struct HomeContinue: View {
    @Environment(AppModel.self) private var model
    let develop: DevelopModel

    var body: some View {
        if let last = develop.attempts.max(by: { $0.at < $1.at }) {
            Button {
                if !last.work.isEmpty {
                    #if os(macOS)
                    model.selection = .smart(.sketches)
                    #else
                    if DeviceInfo.isPad { model.selection = .smart(.sketches) }
                    #endif
                    model.selectedItemID = last.work
                } else {
                    model.openLearn()
                }
            } label: {
                HStack(spacing: Theme.Space.l) {
                    Image(systemName: last.work.isEmpty ? "graduationcap" : "pencil.and.scribble")
                        .font(.title3).foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(last.label.isEmpty ? "Your last question" : last.label).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(DevelopModel.ago(last.at)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(Theme.Space.l)
                .card(cornerRadius: Theme.Radius.large)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Jump back in and Pinned: notes, sketches and clips, smaller. Worked out when the library changes, off the
/// main thread, never in `body`.
private struct HomeShelves: View {
    @Environment(AppModel.self) private var model
    @State private var recent: [Item] = []
    @State private var pinned: [Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HomeShelf(title: "Jump back in", items: recent)
            HomeShelf(title: "Pinned", items: pinned)
        }
        .task(id: model.dataVersion) {
            let items = model.items
            let (r, p) = await Task.detached(priority: .userInitiated) { () -> ([Item], [Item]) in
                let recent = Array(items.lazy.filter { !$0.isPinned }.sorted { $0.createdAt > $1.createdAt }.prefix(10))
                return (recent, Array(items.filter(\.isPinned).prefix(10)))
            }.value
            recent = r
            pinned = p
        }
    }
}

private struct HomeShelf: View {
    @Environment(AppModel.self) private var model
    let title: String
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title).font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(items) { item in
                            Button { open(item) } label: { ItemCard(item: item).frame(width: 168) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Opens an item where the library shows it (the iPhone pushes it onto the Library tab).
    private func open(_ item: Item) {
        #if os(macOS)
        model.selection = .smart(.recent)
        #else
        if DeviceInfo.isPad { model.selection = .smart(.recent) }
        #endif
        model.selectedItemID = item.id
    }
}

/// New note, New sketch and Import: small, at the bottom.
private struct HomeMakeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button { Task { await model.newNote() } } label: { Label("New note", systemImage: "square.and.pencil") }
            Button { Task { await model.newSketch() } } label: { Label("New sketch", systemImage: "pencil.tip.crop.circle") }
            Button { model.selection = .importer } label: { Label("Import", systemImage: "square.and.arrow.down.on.square") }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
