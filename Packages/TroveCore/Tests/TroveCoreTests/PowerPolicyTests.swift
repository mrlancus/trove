import Foundation
import Testing
@testable import TroveCore

@Suite struct PowerPolicyTests {
    @Test func followsTheDeviceState() {
        let battery = PowerPolicy(PowerState())
        #expect(!battery.saving && !battery.unlimited)
        #expect(battery.enrichment == .battery)
        #expect(battery.pingWindow == 0 && battery.minPoll == 0)
        #expect(battery.checkpoints)

        let lowPower = PowerPolicy(PowerState(lowPowerMode: true))
        #expect(lowPower.saving)
        #expect(lowPower.enrichment == .none)
        #expect(lowPower.pingWindow == 60 && lowPower.minPoll == 300)
        #expect(lowPower.recognition == .fast)
        #expect(!lowPower.checkpoints)
        #expect(!lowPower.clipboardImages)

        let charging = PowerPolicy(PowerState(charging: true))
        #expect(charging.unlimited && charging.enrichment == .full && charging.checkpoints)
        // Low Power Mode switches itself off on the charger; until it does, the charger wins.
        #expect(!PowerPolicy(PowerState(lowPowerMode: true, charging: true)).saving)
    }

    @Test func sketchingHoldsBackEverythingButTheInk() {
        let p = PowerPolicy(PowerState(sketching: true))
        #expect(p.enrichment == .none)
        #expect(!p.checkpoints)
        #expect(!p.backgroundRefresh)
        #expect(p.pingWindow == 30)
        #expect(p.minPoll == 120)
        #expect(p.pushRule == PushCoalescer.Rule(quiet: 30, minGap: 60, maxHold: 180))
        // On the charger a checkpoint may still be written mid-sketch.
        #expect(PowerPolicy(PowerState(charging: true, sketching: true)).checkpoints)
        let lowPower = PowerPolicy(PowerState(lowPowerMode: true, sketching: true))
        #expect(lowPower.pushRule.minGap == 180)
        #expect(lowPower.pingWindow == 60)
    }

    @Test func heat() {
        let serious = PowerPolicy(PowerState(mode: .fullSpeed, charging: true, thermal: .serious))
        #expect(serious.saving && !serious.unlimited)
        #expect(serious.enrichment == .none)
        #expect(!serious.checkpoints)
        let critical = PowerPolicy(PowerState(thermal: .critical, sketching: true))
        #expect(critical.onlyOnClose)
        #expect(critical.pushRule.flushOnly)
        #expect(critical.pingWindow == nil && critical.minPoll == nil)
        #expect(!PowerPolicy(PowerState(thermal: .critical)).onlyOnClose)
    }

    @Test func theSetting() {
        let save = PowerPolicy(PowerState(mode: .saveBattery, charging: true))
        #expect(save.saving && !save.unlimited)
        let full = PowerPolicy(PowerState(mode: .fullSpeed, lowPowerMode: true))
        #expect(!full.saving && full.unlimited)
        #expect(full.enrichment == .full)
    }

    @Test func batteryBudgetTakesOnlyThisDevicesLastHour() {
        let b = EnrichmentBudget.battery
        let now = 10_000.0
        #expect(b.takes(creator: "IPAD", device: "IPAD", created: now - 600, now: now))
        #expect(!b.takes(creator: "MAC", device: "IPAD", created: now - 600, now: now))
        #expect(!b.takes(creator: "IPAD", device: "IPAD", created: now - 7200, now: now))
        #expect(EnrichmentBudget.full.takes(creator: "MAC", device: "IPAD", created: 0, now: now))
        #expect(EnrichmentBudget.none.isNone)
    }
}

@Suite struct PushCoalescerTests {
    @Test func waitsForAPauseButNotForever() {
        var c = PushCoalescer(rule: .init(quiet: 30, minGap: 60, maxHold: 180))
        #expect(c.dueTime() == nil)
        c.edited(at: 0)
        #expect(c.dueTime() == 30)
        c.edited(at: 20)
        #expect(c.dueTime() == 50)
        // Writing without a 30 s pause: out after 3 minutes anyway.
        for t in stride(from: 25.0, through: 200, by: 5) { c.edited(at: t) }
        #expect(c.dueTime() == 180)
        #expect(c.isDue(at: 180) && !c.isDue(at: 179))
        c.pushed(at: 180)
        #expect(!c.hasPending && c.dueTime() == nil)
        // Never sooner than a minute after the last push, pause or not.
        c.edited(at: 185)
        #expect(c.dueTime() == 240)
    }

    @Test func pageChangeAndFlushOnly() {
        var c = PushCoalescer(rule: .init(quiet: 30, minGap: 60, maxHold: 180))
        c.pageChanged()
        #expect(c.dueTime() == nil) // nothing waiting
        c.edited(at: 0)
        c.pushed(at: 10)
        c.edited(at: 20)
        c.pageChanged()
        #expect(c.dueTime() == 70) // as soon as the minute since the last push is up
        c.pushed(at: 70)
        c.edited(at: 200)
        c.pageChanged()
        #expect(c.dueTime() == 200)

        var hot = PushCoalescer(rule: .onlyOnFlush)
        hot.edited(at: 0)
        #expect(hot.dueTime() == nil && hot.hasPending)
    }

    /// The simulated 3-hour writing session (docs/ROADMAP.md §3.7): about 60 pushes with the batching,
    /// against about three times as many with the old rule (save 4 s after a pause, push 8 s after the save).
    @Test func aThreeHourWritingSession() {
        let session = Self.writingSession(hours: 3)
        let sketching = PowerPolicy(PowerState(sketching: true)).pushRule
        let new = Self.pushes(session, rule: sketching)
        let old = Self.oldPushes(session)
        print("3-hour writing session: \(session.strokes.count) strokes, \(session.pages.count) page changes; pushes \(old) before → \(new) batched")
        #expect(new >= 50 && new <= 75)
        #expect(old > 2 * new)
        let lowPower = Self.pushes(session, rule: PowerPolicy(PowerState(lowPowerMode: true, sketching: true)).pushRule)
        #expect(lowPower <= 45)
    }

    struct Session {
        var strokes: [Double] = []
        var pages: [Double] = []
        var end: Double = 0
    }

    /// Note-taking as a seeded random walk: strokes 0.3–2 s apart in bursts of 10–60 s, thinking
    /// pauses of 3–25 s between bursts, a longer look-away (40–120 s) now and then, and a new page
    /// every 6–12 minutes.
    static func writingSession(hours: Double) -> Session {
        var rng = SeededRandom(seed: 7)
        var s = Session()
        let end = hours * 3600
        var t = 0.0
        var nextPage = rng.next(in: 360...720)
        while t < end {
            let burstEnd = t + rng.next(in: 10...60)
            while t < burstEnd {
                s.strokes.append(t)
                t += rng.next(in: 0.3...2)
            }
            t += rng.next(in: 0...1) < 0.1 ? rng.next(in: 40...120) : rng.next(in: 3...25)
            if t >= nextPage {
                s.pages.append(t)
                nextPage = t + rng.next(in: 360...720)
            }
        }
        s.end = end
        return s
    }

    /// The rule before: each edit restarts a 4 s save timer; each save restarts an 8 s push timer, which
    /// further strokes don't cancel. So every pause of 4 s or more pushed 8 s later.
    static func oldPushes(_ session: Session) -> Int {
        var count = 0
        var saveAt: Double?
        var pushAt: Double?
        var i = 0
        var now = 0.0
        while now <= session.end + 600 {
            while i < session.strokes.count, session.strokes[i] <= now {
                saveAt = session.strokes[i] + 4
                i += 1
            }
            if let s = saveAt, now >= s { saveAt = nil; pushAt = now + 8 }
            if let p = pushAt, now >= p { pushAt = nil; count += 1 }
            now += 0.5
        }
        return count
    }

    /// Plays the session against a rule, checking once a second like a timer would, and counts pushes.
    static func pushes(_ session: Session, rule: PushCoalescer.Rule) -> Int {
        var c = PushCoalescer(rule: rule)
        var events: [(Double, Bool)] = session.strokes.map { ($0, false) } + session.pages.map { ($0, true) }
        events.sort { $0.0 < $1.0 }
        var count = 0
        var i = 0
        var now = 0.0
        while now <= session.end + 600 {
            while i < events.count, events[i].0 <= now {
                if events[i].1 { c.pageChanged() } else { c.edited(at: events[i].0) }
                i += 1
            }
            if c.isDue(at: now) {
                c.pushed(at: now)
                count += 1
            }
            now += 1
        }
        return count
    }
}

@Suite struct ThrottleTests {
    @Test func mergesWhatComesClose() {
        var t = Throttle(interval: 30)
        #expect(t.request(at: 0) == .now)
        #expect(t.request(at: 5) == .after(25))
        #expect(t.request(at: 10) == .waiting)
        t.ran(at: 30)
        #expect(t.request(at: 40) == .after(20))
        t.cancel()
        #expect(t.request(at: 70) == .now)
        var off = Throttle(interval: 0)
        #expect(off.request(at: 0) == .now)
        #expect(off.request(at: 0) == .now)
    }
}

@Suite struct VectorCacheTests {
    @Test func roundTripsAndIsSmall() throws {
        var entries: [String: VectorCache.Entry] = [:]
        var rng = SeededRandom(seed: 3)
        for i in 0..<200 {
            let v = (0..<512).map { _ in Float(rng.next(in: -1...1)) }
            entries["item-\(i)"] = .init(version: "1700000000000-\(i)-DEVICE", vector: v)
        }
        entries["empty"] = .init(version: "", vector: [])
        let data = VectorCache.encode(entries)
        #expect(VectorCache.decode(data) == entries)
        // 4 bytes a float, against ~10 as JSON text.
        #expect(data.count < 200 * 512 * 4 + 200 * 64)
        #expect(VectorCache.decode(Data("{\"format\":1}".utf8)) == nil)
        #expect(VectorCache.decode(data.prefix(data.count - 3)) == nil)
    }
}

@Suite struct CheckpointPowerTests {
    @Test func noCheckpointWhileNotAllowed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trove-power-\(UUID().uuidString)")
        let keys = VaultKeys.generate()
        let engine = SyncEngine(device: "IPAD", keys: keys, transports: [FolderTransport(root: dir, name: "icloud")])
        for i in 0..<(SyncEngine.checkpointAfterOps / 2 + 10) {
            await engine.set(["title": .string("n\(i)"), "kind": "note"], record: "n\(i)", kind: "item")
            _ = await engine.editText("body", value: "b", record: "n\(i)")
        }
        await engine.allowCheckpoints(false)
        let held = await engine.sync()
        #expect(held.errors.isEmpty)
        #expect(held.wroteCheckpoint == nil)
        await engine.allowCheckpoints(true)
        let wrote = await engine.sync()
        #expect(wrote.wroteCheckpoint != nil)
    }
}

/// A small deterministic generator (SplitMix64) so the simulated session is the same on every run.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
