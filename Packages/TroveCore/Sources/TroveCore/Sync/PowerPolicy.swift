import Foundation

/// Battery on iPad and iPhone (docs/ROADMAP.md §3.7). One place decides how hard the apps work:
/// AppModel, EnrichmentService and SyncEngine read a `PowerPolicy` made from the device's state
/// instead of each guessing at Low Power Mode on its own. Pure values, so they're tested on Linux.
public struct PowerState: Sendable, Equatable {
    /// Settings → Battery (per device, not synced).
    public enum Mode: String, Sendable, CaseIterable, Codable {
        /// Follows Low Power Mode, the charger and heat.
        case automatic
        /// Always as careful as Low Power Mode.
        case saveBattery
        /// Works as if on the charger (heat still slows it down).
        case fullSpeed
    }

    /// `ProcessInfo.ThermalState`, without Foundation's Apple-only type.
    public enum Thermal: Int, Sendable, Comparable, Codable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    public var mode: Mode
    public var lowPowerMode: Bool
    /// On the charger (or a Mac on mains power).
    public var charging: Bool
    public var thermal: Thermal
    /// A sketch is open (on iPhone/iPad it fills the screen).
    public var sketching: Bool

    public init(mode: Mode = .automatic, lowPowerMode: Bool = false, charging: Bool = false,
                thermal: Thermal = .nominal, sketching: Bool = false) {
        self.mode = mode
        self.lowPowerMode = lowPowerMode
        self.charging = charging
        self.thermal = thermal
        self.sketching = sketching
    }
}

public struct PowerPolicy: Sendable, Equatable {
    public let state: PowerState

    public init(_ state: PowerState) { self.state = state }

    /// Plugged in, or told to go full speed: work as before.
    public var unlimited: Bool {
        guard state.thermal < .serious else { return false }
        return state.mode == .fullSpeed || (state.charging && state.mode == .automatic)
    }

    /// Low Power Mode rules: Low Power Mode itself, "Save battery", or a hot device.
    public var saving: Bool {
        if state.thermal >= .serious { return true }
        switch state.mode {
        case .saveBattery: return true
        case .fullSpeed: return false
        case .automatic: return state.lowPowerMode && !state.charging
        }
    }

    /// Very hot while sketching: sync only when the sketch closes or the app goes to the background.
    public var onlyOnClose: Bool { state.thermal == .critical && state.sketching }

    // MARK: Sync

    /// When local edits go out (see `PushCoalescer`).
    public var pushRule: PushCoalescer.Rule {
        if onlyOnClose { return .onlyOnFlush }
        if state.sketching {
            // A real pause (30 s) or 3 minutes of writing sends what's new; never more than once a
            // minute (3 and 5 minutes when saving).
            return saving ? PushCoalescer.Rule(quiet: 30, minGap: 180, maxHold: 300)
                          : PushCoalescer.Rule(quiet: 30, minGap: 60, maxHold: 180)
        }
        return saving ? PushCoalescer.Rule(quiet: 2, minGap: 30, maxHold: nil)
                      : PushCoalescer.Rule(quiet: 2, minGap: 0, maxHold: nil)
    }

    /// Live pings (another device saved something) arriving within this many seconds share one sync.
    /// Zero: sync on every ping. Nil: don't sync on pings at all (until close or background).
    public var pingWindow: Double? {
        if onlyOnClose { return nil }
        if saving { return 60 }
        if state.sketching { return 30 }
        return 0
    }

    /// The shortest wait between background sync rounds (nil: no polling at all).
    public var minPoll: Double? {
        if onlyOnClose { return nil }
        if saving { return 300 }
        if state.sketching { return 120 }
        return 0
    }

    /// Checkpoints (PROTOCOL.md §3) rewrite the whole vault: on the charger, or when nothing is open.
    public var checkpoints: Bool {
        if state.thermal >= .serious { return false }
        return state.charging || (!state.sketching && !saving)
    }

    // MARK: Background work

    /// Enrichment (text recognition, meaning, AI) while the app is open.
    public var enrichment: EnrichmentBudget {
        if state.sketching || state.thermal >= .serious { return .none }
        if unlimited { return .full }
        if saving { return .none }
        return .battery
    }

    /// The overnight task on the charger (`BGProcessingTask` with `requiresExternalPower`).
    public static let overnight = EnrichmentBudget(items: 20, onlyOwnSince: nil, handwriting: 5, recognition: .accurate)

    /// Text recognition for handwriting: `.fast` when saving.
    public var recognition: EnrichmentBudget.Recognition { saving ? .fast : .accurate }

    /// Whether the widget, Spotlight and search-by-meaning should refresh now.
    public var backgroundRefresh: Bool { !state.sketching && state.thermal < .critical }

    /// Copy pictures from the clipboard automatically (iPhone/iPad when the app opens).
    public var clipboardImages: Bool { !saving }

    // MARK: How often the side requests run (one sync round used to make all of them)

    /// The relay's inbox: on a live ping, when the app becomes active, or every 15 minutes.
    public static let inboxEvery: Double = 15 * 60
    /// Price watches: every 6 hours.
    public static let priceWatchesEvery: Double = 6 * 60 * 60
    /// Caches (meaning vectors, search index) are written after this long without changes, on
    /// background, or at once on the charger.
    public static let cacheQuiet: Double = 60
    /// The widget reloads at most this often.
    public static let widgetEvery: Double = 15 * 60
}

/// How much enrichment one round may do.
public struct EnrichmentBudget: Sendable, Equatable {
    public enum Recognition: String, Sendable { case accurate, fast }

    /// Items and clips to enrich (link pages, text in pictures, AI names and summaries).
    public var items: Int
    /// Only items this device saved within this many seconds (nil: anything in the queue).
    public var onlyOwnSince: Double?
    /// Sketches from other devices whose handwriting to read.
    public var handwriting: Int
    public var recognition: Recognition

    public init(items: Int, onlyOwnSince: Double?, handwriting: Int, recognition: Recognition) {
        self.items = items
        self.onlyOwnSince = onlyOwnSince
        self.handwriting = handwriting
        self.recognition = recognition
    }

    public static let none = EnrichmentBudget(items: 0, onlyOwnSince: nil, handwriting: 0, recognition: .fast)
    /// On the charger: as before the battery work.
    public static let full = EnrichmentBudget(items: 20, onlyOwnSince: nil, handwriting: 5, recognition: .accurate)
    /// On battery: what this device saved in the last hour, five at a time; the rest waits for the charger.
    public static let battery = EnrichmentBudget(items: 5, onlyOwnSince: 60 * 60, handwriting: 0, recognition: .accurate)

    public var isNone: Bool { items == 0 && handwriting == 0 }

    /// Whether this budget takes an item made by `creator` at `created` (seconds), seen at `now`.
    public func takes(creator: String?, device: String, created: Double, now: Double) -> Bool {
        guard let since = onlyOwnSince else { return true }
        return creator == device && now - created <= since
    }
}

/// Batches pushes while writing (docs/ROADMAP.md §3.7 item 2). Every pause used to save after 4 s
/// and push 8 s later: a new segment, an iCloud file, a relay PUT and a live ping that woke every
/// other device. Now an edit is pushed once the pen has rested `quiet` seconds, or after `maxHold`
/// of continuous writing, but never sooner than `minGap` after the last push. A page change asks
/// for a push as soon as the gap allows; closing the sketch and going to the background push at once.
public struct PushCoalescer: Sendable, Equatable {
    public struct Rule: Sendable, Equatable {
        public var quiet: Double
        public var minGap: Double
        /// Nil: wait for a pause however long the writing goes on.
        public var maxHold: Double?
        /// Only `flush` pushes (a very hot device while sketching).
        public var flushOnly: Bool

        public init(quiet: Double, minGap: Double, maxHold: Double?, flushOnly: Bool = false) {
            self.quiet = quiet
            self.minGap = minGap
            self.maxHold = maxHold
            self.flushOnly = flushOnly
        }

        public static let onlyOnFlush = Rule(quiet: .infinity, minGap: 0, maxHold: nil, flushOnly: true)
    }

    public var rule: Rule
    /// When the oldest edit not yet pushed was made (nil: nothing waiting).
    public private(set) var firstPending: Double?
    public private(set) var lastEdit: Double?
    public private(set) var lastPush: Double?
    /// A page change asked for a push as soon as the gap allows.
    public private(set) var soon = false

    public init(rule: Rule) { self.rule = rule }

    public var hasPending: Bool { firstPending != nil }

    /// A local edit at `time`.
    public mutating func edited(at time: Double) {
        if firstPending == nil { firstPending = time }
        lastEdit = time
    }

    /// The page changed: push what's waiting as soon as `minGap` allows.
    public mutating func pageChanged() {
        if hasPending { soon = true }
    }

    /// When the waiting edits should go out (nil: nothing waiting, or only a flush pushes them).
    public func dueTime() -> Double? {
        guard let first = firstPending, let last = lastEdit, !rule.flushOnly else { return nil }
        var due = soon ? last : last + rule.quiet
        if let hold = rule.maxHold { due = min(due, first + hold) }
        if let pushed = lastPush { due = max(due, pushed + rule.minGap) }
        return due
    }

    public func isDue(at now: Double) -> Bool {
        guard let due = dueTime() else { return false }
        return now >= due
    }

    /// Everything waiting went out at `time` (a push of ours, or a sync that pushed for another reason).
    public mutating func pushed(at time: Double) {
        firstPending = nil
        lastEdit = nil
        soon = false
        lastPush = time
    }
}

/// Merges requests that come close together (live pings, widget reloads): the first runs at once,
/// those within `interval` after it share one run at the end of the interval.
public struct Throttle: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case now
        /// Run after this many seconds.
        case after(Double)
        /// A run is already waiting; nothing to do.
        case waiting
    }

    public var interval: Double
    public private(set) var lastRun: Double?
    public private(set) var scheduled = false

    public init(interval: Double) { self.interval = interval }

    public mutating func request(at now: Double) -> Decision {
        if scheduled { return .waiting }
        guard let last = lastRun, now - last < interval else {
            lastRun = now
            return .now
        }
        scheduled = true
        return .after(last + interval - now)
    }

    /// The waiting run ran at `time`.
    public mutating func ran(at time: Double) {
        scheduled = false
        lastRun = time
    }

    /// The waiting run was dropped (say the app went to the background).
    public mutating func cancel() { scheduled = false }
}

/// What a sketch session (or the time since launch) cost, shown under Settings → Battery.
public struct PowerCounters: Sendable, Equatable, Codable {
    public var started: Date
    public var ended: Date?
    public var syncRounds = 0
    public var pushes = 0
    public var pulls = 0
    /// Relay or iCloud requests outside the segments: inbox, price watches, AI status, link pages.
    public var otherRequests = 0
    public var livePings = 0
    public var inkReloads = 0
    public var visionPages = 0
    public var aiCalls = 0
    /// Saves of the local copy (only what changed goes into SQLite).
    public var saves = 0
    /// Bytes written to the caches (search index, meaning vectors).
    public var cacheBytes = 0

    public init(started: Date = Date()) { self.started = started }

    public var requests: Int { pushes + pulls + otherRequests }
}
