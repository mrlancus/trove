import XCTest
@testable import TroveCore

final class MathAssistTests: XCTestCase {
    func value(_ s: String, _ env: [String: Double] = [:]) -> Double? {
        if case .value(let v) = MathAssist.solve(s, env: env) { return v }
        return nil
    }

    func testArithmetic() {
        XCTAssertEqual(value("12×4.5 ="), 54)
        XCTAssertEqual(value("2(3+4)="), 14)
        XCTAssertEqual(value("2^10="), 1024)
        XCTAssertEqual(value("3²+4²="), 25)
        XCTAssertEqual(value("√16 + 3 ="), 7)
        XCTAssertEqual(value("10 ÷ 4 ="), 2.5)
        XCTAssertEqual(value("15% of 80 ="), 12)
        XCTAssertEqual(value("5! ="), 120)
        XCTAssertEqual(value("-3 - -2 ="), -1)
        XCTAssertEqual(value("sin(30)="), 0.5)
        XCTAssertEqual(value("1,000 + 1 ="), 1001)
        XCTAssertEqual(value("2π=")!, 2 * .pi, accuracy: 1e-12)
        XCTAssertEqual(MathAssist.solve("2+="), .unsure)
        XCTAssertEqual(MathAssist.solve("1/0="), .unsure)
    }

    func testChecksSolvesAndVariables() {
        XCTAssertEqual(MathAssist.solve("2+2=4"), .check(correct: true, left: 4, right: 4))
        XCTAssertEqual(MathAssist.solve("2+2=5"), .check(correct: false, left: 4, right: 5))
        XCTAssertEqual(MathAssist.solve("2x+3=7"), .solved("x", 2))
        XCTAssertEqual(MathAssist.solve("3(y-1)=2y+4"), .solved("y", 7))
        XCTAssertEqual(MathAssist.solve("x^2=4"), .unsure) // not linear: not guessed
        XCTAssertEqual(MathAssist.solve("a = 5"), .assignment("a", 5))
        XCTAssertEqual(value("3a =", ["a": 5]), 15)
    }

    func testWorkedSolutionSteps() {
        let steps = MathAssist.check(lines: ["2x+3=7", "2x=4", "x=3"])
        XCTAssertEqual(steps[0].outcome, .solved("x", 2))
        XCTAssertEqual(steps[1].followsFromPrevious, true)
        XCTAssertEqual(steps[2].followsFromPrevious, false)
        let defs = MathAssist.check(lines: ["a = 4", "b = a*2", "a+b="])
        XCTAssertEqual(defs[2].outcome, .value(12))
    }

    func testMessyHandwritingPicksTheMathsReading() {
        // Recognisers read "1" as "l", "5" as "S", "+" as "t", "2" as "z".
        let r1 = MathCandidates.best([.init("l2 t S =", 0.6)])
        XCTAssertEqual(r1?.outcome, .value(17))
        let r2 = MathCandidates.best([.init("hello", 0.9), .init("z x 3 =", 0.4)])
        XCTAssertEqual(r2?.outcome, .value(6))
        // "O" for zero, "b" for six.
        XCTAssertEqual(MathCandidates.best([.init("1O - b =", 0.5)])?.outcome, .value(4))
        // A variable that's defined on the page is preferred over turning it into a digit.
        XCTAssertEqual(MathCandidates.best([.init("2b =", 0.7)], env: ["b": 3])?.outcome, .value(6))
        // Nothing sensible: no answer at all.
        XCTAssertNil(MathCandidates.best([.init("@@@", 0.9)]))
    }

    func testEqualsDetectorAndLineGathering() {
        func stroke(_ id: String, _ pts: [(Double, Double)]) -> MathStroke {
            MathStroke(id: id, points: pts.map { InkPoint(x: $0.0, y: $0.1, pressure: 0.5, t: 0) })
        }
        let top = stroke("e1", [(100, 100), (110, 100.5), (120, 100)])
        let bottom = stroke("e2", [(100, 108), (110, 108), (121, 108.5)])
        guard let eq = EqualsDetector.equals(top, bottom) else { return XCTFail("= not seen") }
        // A minus sign alone, or a dash and a far one, isn't "=".
        XCTAssertNil(EqualsDetector.equals(top, stroke("far", [(100, 160), (120, 160)])))
        XCTAssertNil(EqualsDetector.equals(top, stroke("vertical", [(110, 95), (110, 115)])))
        // A scribble isn't a dash.
        XCTAssertFalse(EqualsDetector.isDash(stroke("zig", [(0, 0), (10, 3), (0, 3), (10, 0), (0, 2), (10, 1)])))
        let digits = [stroke("d1", [(60, 95), (62, 112)]), stroke("d2", [(70, 95), (78, 112)]), stroke("d3", [(84, 95), (92, 112)])]
        let farAway = stroke("old", [(-200, 100), (-190, 110)])
        let otherLine = stroke("below", [(60, 200), (90, 215)])
        let line = MathLine.gather(equals: eq, excluding: ["e1", "e2"], from: digits + [farAway, otherLine, top, bottom])
        XCTAssertEqual(line.map(\.id), ["d1", "d2", "d3"])
        XCTAssertEqual(MathLine.key(line), MathLine.key(line.reversed()))
    }

    func testCacheMeansOneRecognitionPerLine() {
        var cache = MathCache(capacity: 2)
        let key = "k1"
        XCTAssertNil(cache.reading(for: key))
        cache.store(nil, for: key)        // an unsure line is cached too
        XCTAssertNotNil(cache.reading(for: key))
        XCTAssertEqual(cache.recognitions, 1)
        cache.store(nil, for: "k2"); cache.store(nil, for: "k3")
        XCTAssertNil(cache.reading(for: key)) // evicted
    }

    func testBatteryPolicy() {
        let saving = PowerPolicy(PowerState(lowPowerMode: true))
        XCTAssertEqual(MathAssist.effectiveMode(.automatic, policy: saving), .onRequest)
        XCTAssertEqual(MathAssist.effectiveMode(.automatic, policy: PowerPolicy(PowerState())), .automatic)
        XCTAssertEqual(MathAssist.effectiveMode(.off, policy: PowerPolicy(PowerState())), .off)
    }

    /// An hour of writing maths: ~120 lines, each written then glanced at; the recogniser must run
    /// once per new or changed line, never on redraws or untouched lines.
    func testAnHourOfMathsReadsEachLineOnce() {
        var cache = MathCache()
        var lines: [String] = []
        for i in 0..<120 { lines.append("line-\(i)") }
        for (i, line) in lines.enumerated() {
            for _ in 0..<5 {   // the page redraws, the line is looked at again
                if cache.reading(for: line) == nil { cache.store(nil, for: line) }
            }
            if i % 10 == 0 { // one line in ten is corrected: a new key
                let edited = line + "-edited"
                if cache.reading(for: edited) == nil { cache.store(nil, for: edited) }
            }
        }
        XCTAssertEqual(cache.recognitions, 132)
    }
}

final class NoteMathTests: XCTestCase {
    func testAnswersLinesEndingInEquals() {
        XCTAssertEqual(MathAssist.noteAnswer(line: "12 * 4 =", before: []), "48")
        XCTAssertEqual(MathAssist.noteAnswer(line: "r * 12 =", before: ["Budget", "r = 900"]), "10800")
        XCTAssertNil(MathAssist.noteAnswer(line: "Meeting notes =", before: []))
        XCTAssertNil(MathAssist.noteAnswer(line: "2 + 2", before: []))
    }
}
