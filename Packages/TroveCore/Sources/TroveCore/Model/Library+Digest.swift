import Foundation

/// Writing digests and AI results into the library (PROTOCOL.md §11), like web/public/aiactions.js.
extension Library {
    /// Writes (or rewrites) a digest note under its week's id and returns the id.
    @discardableResult
    public func writeDigest(_ note: Digest.Note, aiModel: String? = nil) async -> String {
        let id = note.id
        if await engine.record(id) != nil {
            await engine.set(["_deleted": .bool(false), Field.title: .string(note.title)], record: id, kind: "item")
            await setBody(id, note.body)
        } else {
            await addNote(title: note.title, body: note.body, tags: ["digest"], id: id)
        }
        var fields: [String: JSONValue] = [
            "digest": .object(["year": .number(Double(note.week.year)), "week": .number(Double(note.week.week))]),
            Field.needsEnrichment: .bool(false),
        ]
        if let aiModel { fields["ai"] = .object(["where": .string("cloud"), "model": .string(aiModel)]) }
        await update(id, fields)
        return id
    }

    /// Once a week the first device to open writes last week's digest. The id is the same on every
    /// device; a digest the user deleted isn't made again; a week with nothing new gets none.
    @discardableResult
    public func autoDigest(now: Date = Date()) async -> String? {
        let week = Digest.previousWeek(now)
        guard await engine.record(Digest.id(for: week)) == nil else { return nil }
        let note = Digest.weekly(await items(), week: week)
        guard note.saved + note.written > 0 else { return nil }
        return await writeDigest(note)
    }

    /// Saves flashcards as a note: `flashcards: [{front, back}]` plus the same cards in the body.
    @discardableResult
    public func addFlashcards(_ cards: [(front: String, back: String)], title: String, from source: Item?, where place: String, model: String) async -> String {
        var lines: [String] = []
        if let source { lines += ["Flashcards from [[\(Digest.linkTitle(source.displayTitle))]]", ""] }
        for card in cards { lines += ["**Q:** \(card.front)", "**A:** \(card.back)", ""] }
        lines.append(place == "cloud" ? "_Made in the cloud (\(model))._" : "_Made on this device._")
        let id = await addNote(title: title, body: lines.joined(separator: "\n"), tags: ["flashcards"])
        let json: [JSONValue] = cards.map { .object(["front": .string($0.front), "back": .string($0.back)]) }
        await update(id, ["flashcards": .array(json), "ai": .object(["where": .string(place), "model": .string(model)]),
                          Field.needsEnrichment: .bool(false)])
        if let source { await connect(id, source.id) }
        return id
    }
}
