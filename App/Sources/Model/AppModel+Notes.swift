import Foundation
import TroveCore

/// The daily note, templates and checklists (PROTOCOL.md §12).
extension AppModel {
    /// Opens today's note, making it from your "Daily note" template (or the built-in one) if it isn't there.
    func openToday() async {
        guard let library else { return }
        let parts = Notes.DateParts()
        // Another device may have made today's note already: fetch first, so both don't write the template.
        if await library.item(Notes.dailyId(parts)) == nil, sync.lastError == nil { await syncNow() }
        let id = await library.openDaily(parts)
        await reload()
        selectedItemID = id
        Task { await syncNow() }
    }

    /// Your templates, then the built-in ones (from what's loaded, so menus don't wait).
    var noteTemplates: [Notes.Template] { Notes.allTemplates(items) }

    func newNote(from template: Notes.Template) async {
        guard let library else { return }
        // Reading the clipboard asks "Allow Paste?" on iPhone/iPad, so only when the template uses it.
        let clipboard = Notes.usesClipboard(template) ? (Pasteboard.string ?? "") : ""
        let id = await library.addNote(from: template, Notes.DateParts(), clipboard: clipboard)
        await reload()
        selectedItemID = id
    }

    func setTemplate(_ item: Item, _ on: Bool) async {
        await library?.setTemplate(item.id, on)
        await reload()
        toast = on ? "“\(Notes.templateName(item.title))” is now a template" : "No longer a template"
    }
}
