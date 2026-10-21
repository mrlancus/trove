import Testing
@testable import TroveCore

@Suite struct SyncBackoffTests {
    @Test func backsOffWhenQuietAndResetsOnChange() {
        var b = SyncBackoff(base: 30, idleMax: 300, lowPowerMin: 120)
        #expect(b.next(changed: true, lowPower: false) == 30)
        #expect(b.next(changed: false, lowPower: false) == 60)
        #expect(b.next(changed: false, lowPower: false) == 120)
        #expect(b.next(changed: false, lowPower: false) == 240)
        #expect(b.next(changed: false, lowPower: false) == 300)
        #expect(b.next(changed: false, lowPower: false) == 300)
        #expect(b.next(changed: true, lowPower: false) == 30)
    }

    @Test func lowPowerWaitsLonger() {
        var b = SyncBackoff(base: 30, idleMax: 300, lowPowerMin: 120)
        #expect(b.next(changed: true, lowPower: true) == 120)
        #expect(b.next(changed: false, lowPower: true) == 120)
        #expect(b.next(changed: false, lowPower: true) == 120)
        #expect(b.next(changed: false, lowPower: true) == 240)
        var small = SyncBackoff(base: 10, idleMax: 60, lowPowerMin: 120)
        #expect(small.next(changed: true, lowPower: true) == 60)
    }
}
