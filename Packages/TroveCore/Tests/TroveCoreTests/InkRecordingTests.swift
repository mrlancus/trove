import Foundation
import Testing
@testable import TroveCore

struct InkRecordingTests {
    @Test func recordingsLinkStrokesToTheAudio() async throws {
        let lib = Library(engine: SyncEngine(device: "D", keys: nil, encrypted: false))
        let id = await lib.addSketch(title: "Lecture")
        let rec = try await lib.addRecording(Data(repeating: 1, count: 100), to: id, start: 1_000_000, duration: 60)
        #expect(await lib.item(id)?.recordings == [rec])
        #expect(rec.offset(of: 1_030_000) == 30)
        #expect(rec.offset(of: 900_000) == nil)
        let strokes = [(id: "a", createdAt: 1_009_000.0), (id: "b", createdAt: 1_010_000.0), (id: "c", createdAt: 1_020_000.0)]
        #expect(rec.written(at: 10, strokes: strokes) == ["a", "b"])
        await lib.setTranscript("photosynthesis makes glucose", for: rec.id, on: id)
        #expect(await lib.item(id)?.recordings.first?.transcript == "photosynthesis makes glucose")
        await lib.deleteRecording(rec.id, on: id)
        #expect(await lib.item(id)?.recordings.isEmpty == true)
    }
}
