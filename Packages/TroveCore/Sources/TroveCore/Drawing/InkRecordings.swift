import Foundation

/// Audio synced to ink (docs/MASTER_PLAN.md G4, the Notability feature): record while writing,
/// then play back with the strokes written at each moment marked, and start playing from any
/// stroke. Strokes already carry `createdAt`, so the link costs nothing while writing. A sketch's
/// `recordings` field lists them: `[{attachment, start (Unix ms), duration (s), transcript?}]`
/// (PROTOCOL.md §10 "Recordings"). The audio is an ordinary encrypted attachment.
public struct InkRecording: Equatable, Sendable, Identifiable {
    public var attachment: Attachment
    /// When recording began (Unix ms), the clock strokes' `createdAt` use.
    public var start: Double
    public var duration: Double
    public var transcript: String?
    public var id: String { attachment.id }

    public init(attachment: Attachment, start: Double, duration: Double, transcript: String? = nil) {
        self.attachment = attachment; self.start = start; self.duration = duration; self.transcript = transcript
    }

    init?(json: JSONValue) {
        guard let o = json.object, let a = o["attachment"].flatMap(Attachment.init(json:)), let s = o["start"]?.number else { return nil }
        self.init(attachment: a, start: s, duration: o["duration"]?.number ?? 0, transcript: o["transcript"]?.string)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["attachment": attachment.json, "start": .number(start), "duration": .number(duration)]
        if let transcript { o["transcript"] = .string(transcript) }
        return .object(o)
    }

    /// Where in the audio (seconds) a stroke made at `createdAt` was written; nil if outside it.
    public func offset(of createdAt: Double) -> Double? {
        let t = (createdAt - start) / 1000
        return t >= 0 && t <= duration + 1 ? max(0, t) : nil
    }

    /// The strokes written in the `window` seconds up to `time` (seconds into the recording).
    public func written(at time: Double, window: Double = 1.5, strokes: [(id: String, createdAt: Double)]) -> [String] {
        let end = start + time * 1000, begin = end - window * 1000
        return strokes.filter { $0.createdAt >= begin && $0.createdAt <= end }.map(\.id)
    }
}

extension Item {
    public var recordings: [InkRecording] { record["recordings"]?.array?.compactMap(InkRecording.init(json:)) ?? [] }
}

extension Library {
    /// Saves a recording made on a sketch (the audio becomes an encrypted attachment).
    @discardableResult
    public func addRecording(_ audio: Data, to itemId: String, start: Double, duration: Double, mime: String = "audio/mp4") async throws -> InkRecording {
        let blob = try await engine.storeBlob(audio)
        let rec = InkRecording(attachment: Attachment(id: blob, name: "Recording.m4a", mime: mime, size: audio.count), start: start, duration: duration)
        let existing = await item(itemId)?.recordings ?? []
        await update(itemId, ["recordings": .array((existing + [rec]).map(\.json))])
        return rec
    }

    /// Adds a recording's transcript (searchable with the sketch).
    public func setTranscript(_ text: String, for attachmentId: String, on itemId: String) async {
        guard var list = await item(itemId)?.recordings, let i = list.firstIndex(where: { $0.id == attachmentId }) else { return }
        list[i].transcript = text
        await update(itemId, ["recordings": .array(list.map(\.json))])
    }

    public func deleteRecording(_ attachmentId: String, on itemId: String) async {
        guard let list = await item(itemId)?.recordings else { return }
        await update(itemId, ["recordings": .array(list.filter { $0.id != attachmentId }.map(\.json))])
    }
}
