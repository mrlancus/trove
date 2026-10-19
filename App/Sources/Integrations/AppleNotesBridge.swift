#if os(macOS)
import Foundation
import TroveCore

/// Mac only: mirrors Apple Notes into Trove (read-only) so they show up in Trove search, and can
/// save a Trove item into Apple Notes. Uses AppleScript, which needs the Automation permission
/// (System Settings → Privacy & Security → Automation → Trove → Notes). Locked notes and
/// attachments aren't exposed by Notes' scripting dictionary (RESEARCH.md §5).
enum AppleNotesBridge {
    struct Note { var id: String; var name: String; var html: String; var modified: Date; var folder: String }

    static func fetchAll(limit: Int = 2000) throws -> [Note] {
        // Fields joined with ASCII unit/record separators to survive any note content.
        let script = """
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        set out to ""
        tell application "Notes"
            set counter to 0
            repeat with f in folders
                set fname to name of f
                repeat with n in notes of f
                    if counter ≥ \(limit) then exit repeat
                    if password protected of n is false then
                        set out to out & (id of n) & US & (name of n) & US & ((modification date of n) as «class isot» as string) & US & fname & US & (body of n) & RS
                        set counter to counter + 1
                    end if
                end repeat
            end repeat
        end tell
        return out
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else {
            throw NSError(domain: "AppleNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: (error?["NSAppleScriptErrorMessage"] as? String) ?? "Couldn't read Apple Notes"])
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return result.split(separator: "\u{1E}").compactMap { record in
            let f = record.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { return nil }
            return Note(id: f[0], name: f[1], html: f[4], modified: iso.date(from: f[2]) ?? Date(), folder: f[3])
        }
    }

    /// Adds new notes and refreshes changed ones. Notes stay owned by Apple Notes (source .appleNotes).
    static func importAll(into library: Library) async {
        guard let notes = try? fetchAll() else { return }
        let existing = Dictionary(
            (await library.items()).compactMap { item in item.record[Field.origin]?.object?["appleNotesId"]?.string.map { ($0, item) } },
            uniquingKeysWith: { a, _ in a })
        for note in notes {
            let markdown = AppleNotesHTML.markdown(note.html)
            if let item = existing[note.id] {
                let lastSeen = item.record[Field.origin]?.object?["modified"]?.date ?? .distantPast
                guard note.modified > lastSeen.addingTimeInterval(1) else { continue }
                await library.setBody(item.id, markdown)
                await library.update(item.id, [Field.title: .string(note.name),
                                               Field.origin: ["appleNotesId": .string(note.id), "modified": JSONValue(note.modified), "folder": .string(note.folder)]])
            } else {
                let id = await library.addNote(title: note.name, body: markdown, source: .appleNotes)
                await library.update(id, [Field.origin: ["appleNotesId": .string(note.id), "modified": JSONValue(note.modified), "folder": .string(note.folder)],
                                          Field.createdAt: JSONValue(note.modified)])
            }
        }
    }

    static func open(noteId: String) {
        let script = "tell application \"Notes\" to show note id \"\(noteId.replacingOccurrences(of: "\"", with: ""))\"\ntell application \"Notes\" to activate"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    /// "Save to Apple Notes": creates a note from a Trove item.
    static func save(_ item: Item) throws {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var body = "<h1>\(esc(item.displayTitle))</h1>"
        if let url = item.url { body += "<div><a href=\\\"\(esc(url.absoluteString))\\\">\(esc(url.absoluteString))</a></div>" }
        for line in (item.body.isEmpty ? (item.summary ?? "") : item.body).split(separator: "\n", omittingEmptySubsequences: false) {
            body += "<div>\(esc(String(line)))</div>"
        }
        let script = "tell application \"Notes\" to make new note at folder 1 with properties {body:\"\(body)\"}"
        var error: NSDictionary?
        if NSAppleScript(source: script)?.executeAndReturnError(&error) == nil {
            throw NSError(domain: "AppleNotes", code: 2, userInfo: [NSLocalizedDescriptionKey: (error?["NSAppleScriptErrorMessage"] as? String) ?? "Couldn't save to Notes"])
        }
    }
}
#endif
