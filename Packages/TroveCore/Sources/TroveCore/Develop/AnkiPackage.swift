import Crypto
import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

/// An Anki package (`.apkg`, docs/DEVELOP_PLAN.md §B3 point 8): a zip of a SQLite collection in the
/// legacy schema 11 (`collection.anki2`, which current Anki still imports) and a `media` map. Notes keep
/// the GUIDs `AnkiExport.guid` gives, and the note type and deck ids are fixed, so importing a newer
/// export updates the same notes instead of adding copies. Never a `.colpkg` (that replaces a
/// collection). Scheduling isn't exported: Anki schedules what it imports.
public enum AnkiPackage {
    /// Fixed ids, so every export uses the same note type and deck (Anki matches on them).
    public static let modelId: Int64 = 1_700_000_000_123
    public static let deckId: Int64 = 1_700_000_000_456

    public struct Failure: Error, CustomStringConvertible { public var description: String }

    /// The package's bytes. `now` is Unix ms (note and card ids start there).
    public static func make(_ cards: [StudyCard], deck: String = "Trove", now: Int64) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trove-anki-\(UUID().uuidString).anki2")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeCollection(cards, deck: deck, now: now, to: url)
        let collection = try Data(contentsOf: url)
        return Data(ZipWriter.stored([("collection.anki2", Array(collection)), ("media", Array("{}".utf8))]))
    }

    /// Anki's checksum of a note's first field: the first 8 hex digits of its SHA-1, as a number.
    static func checksum(_ field: String) -> Int64 {
        let digest = Insecure.SHA1.hash(data: Data(stripHTML(field).utf8))
        return Int64(digest.prefix(4).reduce(0) { ($0 << 8) | UInt64($1) })
    }

    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func json(_ v: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]), as: UTF8.self)
    }

    static func writeCollection(_ cards: [StudyCard], deck: String, now: Int64, to url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw Failure(description: "can't create the collection") }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
        }
        try exec("""
        CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null,
          dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null,
          dconf text not null, tags text not null);
        CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null,
          tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
        CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null,
          usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null, factor integer not null,
          reps integer not null, lapses integer not null, left integer not null, odue integer not null, odid integer not null,
          flags integer not null, data text not null);
        CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null,
          lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
        CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
        CREATE INDEX ix_notes_usn on notes (usn);
        CREATE INDEX ix_cards_usn on cards (usn);
        CREATE INDEX ix_revlog_usn on revlog (usn);
        CREATE INDEX ix_cards_nid on cards (nid);
        CREATE INDEX ix_cards_sched on cards (did, queue, due);
        CREATE INDEX ix_revlog_cid on revlog (cid);
        CREATE INDEX ix_notes_csum on notes (csum);
        """)
        let secs = now / 1000
        let field = { (name: String, ord: Int) -> [String: Any] in
            ["name": name, "ord": ord, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": [Any]()]
        }
        let model: [String: Any] = [
            "id": modelId, "name": "Trove (Front/Back)", "type": 0, "mod": secs, "usn": -1, "sortf": 0, "did": deckId,
            "tmpls": [["name": "Card 1", "ord": 0, "qfmt": "{{Front}}", "afmt": "{{FrontSide}}<hr id=answer>{{Back}}", "did": NSNull(), "bqfmt": "", "bafmt": ""]],
            "flds": [field("Front", 0), field("Back", 1)],
            "css": ".card { font-family: -apple-system, Helvetica, Arial; font-size: 20px; text-align: center; color: black; background-color: white; }",
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}", "latexsvg": false, "req": [[0, "any", [0]]], "tags": [Any](), "vers": [Any](),
        ]
        func deckJSON(_ id: Int64, _ name: String) -> [String: Any] {
            ["id": id, "name": name, "mod": secs, "usn": -1, "lrnToday": [0, 0], "revToday": [0, 0], "newToday": [0, 0], "timeToday": [0, 0],
             "collapsed": false, "browserCollapsed": false, "desc": "", "dyn": 0, "conf": 1, "extendNew": 0, "extendRev": 0]
        }
        let dconf: [String: Any] = ["1": [
            "id": 1, "name": "Default", "mod": 0, "usn": 0, "maxTaken": 60, "autoplay": true, "timer": 0, "replayq": true, "dyn": false,
            "new": ["bury": false, "delays": [1, 10], "initialFactor": 2500, "ints": [1, 4, 0], "order": 1, "perDay": 20],
            "rev": ["bury": false, "ease4": 1.3, "ivlFct": 1, "maxIvl": 36500, "perDay": 200, "hardFactor": 1.2],
            "lapse": ["delays": [10], "leechAction": 1, "leechFails": 8, "minInt": 1, "mult": 0],
        ]]
        let conf: [String: Any] = ["nextPos": cards.count + 1, "estTimes": true, "activeDecks": [1], "sortType": "noteFld", "timeLim": 0,
                                   "sortBackwards": false, "addToCur": true, "curDeck": 1, "newSpread": 0, "dueCounts": true, "curModel": modelId, "collapseTime": 1200]
        var insert: OpaquePointer?
        let colSQL = "INSERT INTO col VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')"
        guard sqlite3_prepare_v2(db, colSQL, -1, &insert, nil) == SQLITE_OK else { throw Failure(description: "col") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(insert, 1, secs)
        sqlite3_bind_int64(insert, 2, now)
        sqlite3_bind_int64(insert, 3, now)
        for (i, text) in [try json(conf), try json([String(modelId): model]),
                          try json(["1": deckJSON(1, "Default"), String(deckId): deckJSON(deckId, deck)]), try json(dconf)].enumerated() {
            sqlite3_bind_text(insert, Int32(4 + i), text, -1, transient)
        }
        guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
        sqlite3_finalize(insert)

        var note: OpaquePointer?, card: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO notes VALUES (?, ?, ?, ?, -1, ?, ?, ?, ?, 0, '')", -1, &note, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO cards VALUES (?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')", -1, &card, nil) == SQLITE_OK
        else { throw Failure(description: "prepare") }
        defer { sqlite3_finalize(note); sqlite3_finalize(card) }
        try exec("BEGIN")
        for (i, c) in cards.sorted(by: { $0.id < $1.id }).enumerated() {
            let nid = now + Int64(i), cid = now + Int64(i)
            let front = AnkiExport.field(c.front), back = AnkiExport.field(c.back)
            let tags = " trove::" + Develop.slug(c.noteTitle.isEmpty ? "note" : c.noteTitle) + " "
            sqlite3_reset(note)
            sqlite3_bind_int64(note, 1, nid)
            sqlite3_bind_text(note, 2, AnkiExport.guid(c.id), -1, transient)
            sqlite3_bind_int64(note, 3, modelId)
            sqlite3_bind_int64(note, 4, secs)
            sqlite3_bind_text(note, 5, tags, -1, transient)
            sqlite3_bind_text(note, 6, front + "\u{1F}" + back, -1, transient)
            sqlite3_bind_text(note, 7, stripHTML(front), -1, transient)
            sqlite3_bind_int64(note, 8, checksum(front))
            guard sqlite3_step(note) == SQLITE_DONE else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
            sqlite3_reset(card)
            sqlite3_bind_int64(card, 1, cid)
            sqlite3_bind_int64(card, 2, nid)
            sqlite3_bind_int64(card, 3, deckId)
            sqlite3_bind_int64(card, 4, secs)
            sqlite3_bind_int64(card, 5, Int64(i + 1))
            guard sqlite3_step(card) == SQLITE_DONE else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
        }
        try exec("COMMIT")
    }
}
