import Foundation

/// What an item says, for Practise this (learn-pivot plan §6): a note's text, a PDF's or picture's text, a
/// sketch's handwriting, and what was said in its lecture recordings. Kept to `limit` characters (the start of a
/// long lecture is enough for a set of questions; the rest stays for the next set).
public enum LearningMaterial {
    public static let limit = 12_000

    public static func text(of item: Item, limit: Int = limit) -> String {
        var parts: [String] = []
        if !item.displayTitle.isEmpty { parts.append("Title: \(item.displayTitle)") }
        if !item.body.isEmpty { parts.append(item.body) }
        if let ocr = item.ocrText, !ocr.isEmpty { parts.append(ocr) }
        for key in ["sketchText", "inkText"] {
            if let t = item.record[key]?.string, !t.isEmpty { parts.append("Handwriting: " + t) }
        }
        let said = item.recordings.compactMap(\.transcript).filter { !$0.isEmpty }
        if !said.isEmpty { parts.append("Lecture transcript: " + said.joined(separator: "\n")) }
        let text = parts.joined(separator: "\n\n")
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    /// Whether an item has a lecture recording with a transcript ("Make questions from this lecture").
    public static func isLecture(_ item: Item) -> Bool { item.recordings.contains { !($0.transcript ?? "").isEmpty } }
}
