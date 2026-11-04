import Foundation

/// Board papers you've downloaded, kept in your trove so they sync to your other devices like your own
/// uploads (you, 2026-11-04: "can't it technically count as an upload"). One item per catalogue document,
/// with the same id on every device, so two devices downloading the same paper make one item, and the PDF
/// is a content-addressed blob, stored once. They're filed under Practice papers → the board, and not sent
/// for enrichment (hundreds of exam PDFs would cost battery for nothing; the title is what you search).
extension Library {
    public static func boardPaperId(_ docId: String) -> String { "paper." + docId }

    /// Saves a downloaded catalogue document. Already saved (here or on another device): nothing to do.
    @discardableResult
    public func saveBoardPaper(_ data: Data, docId: String, title: String, folder: [String]) async throws -> String {
        let id = Self.boardPaperId(docId)
        if let existing = await boardPaper(docId), !existing.attachments.isEmpty { return id }
        _ = try await addFile(data, name: "\(docId).pdf", mime: "application/pdf", kind: .pdf, source: .app, title: title, id: id, folder: folder)
        await engine.set(["_deleted": .bool(false), Field.needsEnrichment: .bool(false), "boardPaper": .string(docId),
                          Field.enrichment: Enrichment(tier: .basic, by: "develop").json], record: id, kind: "item")
        return id
    }

    /// Which catalogue documents are saved in the trove (one pass over the cached item list).
    public func boardPaperDocIds() async -> Set<String> {
        Set(await items().compactMap { $0.id.hasPrefix("paper.") ? String($0.id.dropFirst(6)) : nil })
    }

    /// The saved copy of a catalogue document, if any device has saved it.
    public func boardPaper(_ docId: String) async -> Item? { await item(Self.boardPaperId(docId)) }

    /// The PDF of a saved board paper; nil until its file has synced to this device.
    public func boardPaperData(_ docId: String) async -> Data? {
        guard let item = await boardPaper(docId), let att = item.attachments.first(where: { $0.mime == "application/pdf" }) else { return nil }
        return try? await attachmentData(att)
    }
}
