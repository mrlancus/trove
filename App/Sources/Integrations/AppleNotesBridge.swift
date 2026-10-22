#if os(macOS)
import Foundation
import TroveCore

/// Mac only: mirrors Apple Notes into Trove (read-only) so they show up in Trove search, and can
/// save a Trove item into Apple Notes. Uses AppleScript, which needs the Automation permission
/// (System Settings → Privacy & Security → Automation → Trove → Notes). Locked notes and
/// attachments aren't exposed by Notes' scripting dictionary (RESEARCH.md §5).
enum AppleNotesBridge {
    struct Note: Decodable, Sendable { var id: String; var name: String; var html: String; var modified: Date; var folder: String }

    /// What went wrong, in words for Settings.
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Every unlocked note, read in bulk per folder with JavaScript for Automation (a note at a time
    /// took minutes and hit Apple Events' two-minute timeout on big libraries). Runs `osascript` off
    /// the main thread, so the app never stalls while Notes answers.
    static func fetchAll() async throws -> [Note] {
        // The notes go to a file, written as UTF-8 by Foundation: osascript's printed result is in
        // the system's default encoding for an app started from Finder, and came back empty or garbled.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trove-apple-notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let path = file.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let script = """
        ObjC.import('Foundation');
        const Notes = Application('Notes');
        const out = [];
        let folders = 0;
        for (const f of Notes.folders()) {
          folders++;
          const folder = f.name();
          if (folder === 'Recently Deleted') continue;
          const notes = f.notes;
          if (notes.length === 0) continue;
          const ids = notes.id(), names = notes.name(), mods = notes.modificationDate(), locked = notes.passwordProtected();
          let bodies;
          try { bodies = notes.body(); } catch (e) { bodies = ids.map((_, i) => { try { return notes[i].body(); } catch (e2) { return ''; } }); }
          for (let i = 0; i < ids.length; i++) {
            if (locked[i]) continue;
            out.push({ id: ids[i], name: names[i] || '', modified: mods[i].toISOString(), folder: folder, html: bodies[i] || '' });
          }
        }
        const text = $.NSString.alloc.initWithUTF8String(JSON.stringify(out));
        const ok = text.writeToFileAtomicallyEncodingError('\(path)', true, $.NSUTF8StringEncoding, null);
        'wrote ' + out.length + ' notes from ' + folders + ' folders: ' + ok;
        """
        let printed = String(decoding: try await run(script, language: "JavaScript"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            throw Failure(message: printed.isEmpty
                ? "Apple Notes didn't answer. Check System Settings → Privacy & Security → Automation → Trove → Notes is on (if Trove isn't listed there, restart Trove and press Import now to be asked)."
                : "Apple Notes answered but no notes were saved (\(printed.prefix(120))).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
        }
        // Whatever came before the JSON (a warning on stdout) is skipped; a note that doesn't decode
        // is left out rather than failing the whole import.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") else {
            throw Failure(message: "Couldn't read what Apple Notes sent back: “\(text.prefix(120))”")
        }
        struct Loose: Decodable { let note: Note? ; init(from d: Decoder) throws { note = try? Note(from: d) } }
        do {
            return try decoder.decode([Loose].self, from: Data(text[start...end].utf8)).compactMap(\.note)
        } catch {
            throw Failure(message: "Couldn't read what Apple Notes sent back (\(data.count) bytes): \(error.localizedDescription)")
        }
    }

    /// Runs a script with `osascript` in the background; its output, or a readable error.
    static func run(_ script: String, language: String = "AppleScript") async throws -> Data {
        try await Task.detached(priority: .utility) { () throws -> Data in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", language, "-e", script]
            var env = ProcessInfo.processInfo.environment
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = "en_US.UTF-8"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { throw Failure(message: "Couldn't start osascript: \(error.localizedDescription)") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw failure(errors) }
            // Nothing printed but something said on stderr: that's the reason.
            if data.isEmpty, !errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw failure(errors) }
            return data
        }.value
    }

    /// osascript's error as something to do about it.
    private static func failure(_ errors: String) -> Failure {
        if errors.contains("-1743") || errors.localizedCaseInsensitiveContains("not authori") {
            return Failure(message: "Trove isn't allowed to read Apple Notes. Turn it on in System Settings → Privacy & Security → Automation → Trove → Notes, then press Import now.")
        }
        if errors.contains("-1712") { return Failure(message: "Apple Notes took too long to answer. Open Notes once, then press Import now.") }
        if errors.contains("-600") { return Failure(message: "Apple Notes isn't running and couldn't be opened.") }
        let line = errors.split(separator: "\n").last.map(String.init) ?? ""
        return Failure(message: line.isEmpty ? "Apple Notes didn't answer." : "Apple Notes: \(line)")
    }

    /// Adds new notes and refreshes changed ones. Notes stay owned by Apple Notes (source .appleNotes).
    @discardableResult
    static func importAll(into library: Library) async throws -> (added: Int, updated: Int, total: Int) {
        let notes = try await fetchAll()
        let existing = Dictionary(
            (await library.items()).compactMap { item in item.record[Field.origin]?.object?["appleNotesId"]?.string.map { ($0, item) } },
            uniquingKeysWith: { a, _ in a })
        var added = 0, updated = 0
        for note in notes {
            let markdown = AppleNotesHTML.markdown(note.html)
            let origin: JSONValue = ["appleNotesId": .string(note.id), "modified": JSONValue(note.modified), "folder": .string(note.folder)]
            if let item = existing[note.id] {
                let lastSeen = item.record[Field.origin]?.object?["modified"]?.date ?? .distantPast
                guard note.modified > lastSeen.addingTimeInterval(1) else { continue }
                await library.setBody(item.id, markdown)
                await library.update(item.id, [Field.title: .string(note.name), Field.origin: origin])
                updated += 1
            } else {
                let id = await library.addNote(title: note.name, body: markdown, source: .appleNotes)
                await library.update(id, [Field.origin: origin, Field.createdAt: JSONValue(note.modified)])
                added += 1
            }
        }
        return (added, updated, notes.count)
    }

    static func open(noteId: String) {
        let script = "tell application \"Notes\" to show note id \"\(noteId.replacingOccurrences(of: "\"", with: ""))\"\ntell application \"Notes\" to activate"
        Task { _ = try? await run(script) }
    }

    /// "Save to Apple Notes": creates a note from a Trove item.
    static func save(_ item: Item) async throws {
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
        _ = try await run(script)
    }
}
#endif
