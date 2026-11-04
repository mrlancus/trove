import SwiftUI
import TroveCore

/// Every paper you've uploaded (and any PDF you practise or put in a goal), in one list: search by any
/// words of its name, its goals or its board; rename, practise, open or delete. Open shows the item as
/// anywhere else in Trove (the PDF, its name, its folder).
struct PapersView: View {
    @Bindable var develop: DevelopModel
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var sort: Sort = .newest
    @State private var everyPDF = false
    @State private var renaming: Item?
    @State private var newName = ""
    @State private var deleting: Item?

    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest", name = "Name", questions = "Most questions"
        var id: String { rawValue }
    }

    var body: some View {
        let counts = Dictionary(develop.problems.compactMap(develop.itemId).map { ($0, 1) }, uniquingKeysWith: +)
        let papers = shown(counts)
        List {
            Section {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Include every PDF in my trove", isOn: $everyPDF)
            } footer: {
                Text("\(papers.count) paper\(papers.count == 1 ? "" : "s"). Search finds any words of a name, a goal or a board, in any order.")
            }
            ForEach(papers) { item in
                NavigationLink { ItemDetailView(item: item) } label: { row(item, questions: counts[item.id] ?? 0) }
                    .contextMenu { actions(item, questions: counts[item.id] ?? 0) }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                        Button("Rename", systemImage: "pencil") { newName = item.displayTitle; renaming = item }.tint(.blue)
                    }
            }
            if papers.isEmpty {
                Text(query.isEmpty ? "No papers yet. Upload one with the + button." : "Nothing matches \"\(query)\".")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Search your papers")
        .navigationTitle("Your papers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                UploadMenu(develop: develop) { Label("Upload", systemImage: "plus") }
            }
        }
        .alert("Rename paper", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let item = renaming { Task { await develop.rename(item, to: newName) } }
                renaming = nil
            }
        }
        .confirmationDialog("Delete \(deleting?.displayTitle ?? "this paper")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = deleting { Task { await model.delete(item); await develop.reload() } }
                deleting = nil
            }
        } message: {
            Text("It's removed from your trove on every device, with its questions.")
        }
    }

    // MARK: Rows

    private func row(_ item: Item, questions: Int) -> some View {
        let goals = develop.goals(using: item.id).map(\.name)
        return HStack(spacing: 12) {
            Image(systemName: "doc.richtext").font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.body).lineLimit(2)
                Text(detail(item, questions: questions, goals: goals)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ item: Item, questions: Int, goals: [String]) -> String {
        var parts = [questions > 0 ? "\(questions) question\(questions == 1 ? "" : "s")" : "Not practised yet"]
        if !goals.isEmpty { parts.append("In " + goals.joined(separator: ", ")) }
        parts.append(item.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func actions(_ item: Item, questions: Int) -> some View {
        Button("Rename…", systemImage: "pencil") { newName = item.displayTitle; renaming = item }
        if questions == 0 {
            Button("Split into questions", systemImage: "scissors") { Task { await develop.split(item: item) } }
        }
        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = item }
    }

    // MARK: The list

    private func shown(_ counts: [String: Int]) -> [Item] {
        let base = everyPDF ? develop.myPDFs : develop.yourPapers
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let found = words.isEmpty ? base : base.filter { item in
            let hay = ([item.displayTitle] + develop.goals(using: item.id).map(\.name)).joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        switch sort {
        case .newest: return found.sorted { $0.createdAt > $1.createdAt }
        case .name: return found.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .questions:
            return found.sorted { (counts[$0.id] ?? 0, $1.displayTitle) > (counts[$1.id] ?? 0, $0.displayTitle) }
        }
    }
}
