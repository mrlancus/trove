import Foundation

/// The daily note, templates and checklists in the library (PROTOCOL.md §12), like the website's Vault.
extension Library {
    /// Today's note: opens it if it's there, else makes it (again, if it was deleted). Returns its id.
    @discardableResult
    public func openDaily(_ parts: Notes.DateParts) async -> String {
        let id = Notes.dailyId(parts)
        if let r = await engine.record(id), !r.isDeleted { return id }
        let made = Notes.daily(await items(), parts)
        if await engine.record(id) != nil {
            await engine.set(["_deleted": .bool(false), Field.title: .string(made.note.title), Field.tags: JSONValue(made.note.tags)],
                             record: id, kind: "item")
            await setBody(id, made.note.body)
        } else {
            await addNote(title: made.note.title, body: made.note.body, tags: made.note.tags, id: id)
        }
        await update(id, ["daily": .string(made.date)])
        return id
    }

    /// A new note from a template. Returns its id.
    @discardableResult
    public func addNote(from template: Notes.Template, _ parts: Notes.DateParts, clipboard: String = "") async -> String {
        let note = Notes.make(from: template, parts, clipboard: clipboard)
        let id = await addNote(title: note.title, body: note.body, tags: note.tags)
        if let category = note.category { await update(id, [Field.category: .string(category)]) }
        return id
    }

    /// Your templates and the built-in ones.
    public func templates() async -> [Notes.Template] { Notes.allTemplates(await items()) }

    /// Makes a note one of your templates (or stops it being one).
    public func setTemplate(_ id: String, _ on: Bool) async {
        guard let item = await item(id) else { return }
        var tags = Set(item.tags)
        if on { tags.insert(Notes.templateTag) } else { tags.remove(Notes.templateTag) }
        await update(id, [Field.tags: JSONValue(tags.sorted())])
    }

    /// Ticks or unticks the `index`th checkbox in a note's body.
    public func toggleCheckbox(_ id: String, at index: Int) async {
        guard let item = await item(id) else { return }
        let body = Notes.toggle(item.body, at: index)
        if body != item.body { await engine.editText(Field.body, value: body, record: id, kind: "item") }
    }
}
