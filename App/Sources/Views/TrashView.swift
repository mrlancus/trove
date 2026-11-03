import SwiftUI
import TroveCore

/// Recently Deleted (MASTER_PLAN N11): anything deleted in the last 30 days, with Restore.
struct TrashView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TrashList()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }
}

/// The list itself, also pushed from Settings → Vault.
struct TrashList: View {
    @Environment(AppModel.self) private var model
    @State private var deleted: [Library.Deleted] = []
    @State private var loaded = false

    var body: some View {
            Group {
                if loaded && deleted.isEmpty {
                    ContentUnavailableView("Nothing deleted recently", systemImage: "trash", description: Text("Deleted items stay here for 30 days."))
                } else {
                    List(deleted) { d in
                        HStack {
                            Thumbnail(item: d.item, square: 36)
                            VStack(alignment: .leading) {
                                Text(d.item.displayTitle).lineLimit(1)
                                Text("Deleted \(d.deletedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                Task {
                                    await model.library?.restore(d.id)
                                    await model.reload()
                                    await load()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .task { await load() }
    }

    private func load() async {
        deleted = await model.library?.recentlyDeleted() ?? []
        loaded = true
    }
}
