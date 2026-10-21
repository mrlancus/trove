import Foundation

/// Ties the local journal, the materialised records and the transports together.
/// Local edits apply instantly; `sync()` pushes this device's segments and pulls everyone else's.
public actor SyncEngine {
    public struct Snapshot: Codable, Sendable {
        public var journal: Journal.State
        public var pending: [Op]
        public var unpushed: [String: [String]]   // transport name → segment keys still to push
        public var applied: [String]               // segment keys already applied
        public var ops: [Op]                       // local cache of every op (rebuilds state offline)
        public var unpushedBlobs: [String: [String]]? // transport name → blob ids still to upload
        public var bridgeBlobs: [String]?               // attachments still to copy between transports
        /// The checkpoint the store starts from (`ops` then holds only what it doesn't cover).
        public var base: Checkpoint?
        /// When this device last wrote a checkpoint or looked for one to write (Unix ms).
        public var checkpointCheckedAt: Double?

        public init(journal: Journal.State, pending: [Op], unpushed: [String: [String]], applied: [String], ops: [Op],
                    unpushedBlobs: [String: [String]]? = nil, bridgeBlobs: [String]? = nil, base: Checkpoint? = nil, checkpointCheckedAt: Double? = nil) {
            self.journal = journal
            self.pending = pending
            self.unpushed = unpushed
            self.applied = applied
            self.ops = ops
            self.unpushedBlobs = unpushedBlobs
            self.bridgeBlobs = bridgeBlobs
            self.base = base
            self.checkpointCheckedAt = checkpointCheckedAt
        }
    }

    /// The small part of the local state, rewritten on every save (`LocalDatabase`); ops, applied
    /// segment keys and the checkpoint are saved apart, a little at a time.
    public struct LocalState: Codable, Sendable, Equatable {
        public var journal: Journal.State
        public var pending: [Op]
        public var unpushed: [String: [String]]
        public var unpushedBlobs: [String: [String]]
        public var bridgeBlobs: [String]
        public var checkpointCheckedAt: Double?
    }

    /// What changed since the last save (`takeSaveDelta`). With `rewrite`, `newOps` and `newApplied`
    /// are everything and the stored copy is replaced; `base` is set when the checkpoint changed.
    public struct SaveDelta: Sendable {
        public var state: LocalState
        public var newOps: [Op]
        public var newApplied: [String]
        public var base: Checkpoint?
        public var baseChanged: Bool
        public var rewrite: Bool
    }

    public struct Report: Sendable, Equatable {
        public var pushed = 0
        public var pulled = 0
        public var errors: [String] = []
        /// The checkpoint this sync started from, or wrote.
        public var loadedCheckpoint: String?
        public var wroteCheckpoint: String?
    }

    /// Write a checkpoint once this many ops have piled up since the last one (PROTOCOL.md §3)…
    public static let checkpointAfterOps = 5000
    /// …and the newest one is at least a day old; look at most once an hour.
    static let checkpointMinAge: Double = 24 * 60 * 60 * 1000
    static let checkpointCheckEvery: Double = 60 * 60 * 1000

    public private(set) var store = RecordStore()
    private var journal: Journal
    private var transports: [any SyncTransport]
    private let keys: VaultKeys?
    private let encrypted: Bool
    /// Copy segments learned from one transport into the others (the Mac bridging iCloud ⇄ relay).
    private let bridge: Bool
    private var applied: Set<String> = []
    private var outbox: [String: Segment] = [:]          // key → segment
    private var unpushed: [String: Set<String>] = [:]     // transport → keys
    private var observers: [UUID: @Sendable () -> Void] = [:]
    /// Encrypted attachment bytes kept on this device (directory, or memory when nil).
    private let blobCache: URL?
    private var memoryBlobs: [String: Data] = [:]
    private var unpushedBlobs: [String: Set<String>] = [:]
    /// Attachments other devices put on one transport that a bridging device still has to copy to the rest.
    private var bridgeBlobs: Set<String> = []
    static let bridgeBlobsPerSync = 40
    /// The checkpoint the store starts from, as written (kept for saving and for the snapshot).
    private var checkpoint: Checkpoint?
    private var checkpointCheckedAt: Double?
    private let clock: @Sendable () -> Int64
    // Saving a little at a time (`takeSaveDelta`).
    private var unsavedOps: [Op] = []
    private var unsavedApplied: [String] = []
    private var baseChanged = false
    private var needsRewrite = true

    public init(device: String, keys: VaultKeys?, encrypted: Bool = true, transports: [any SyncTransport] = [], bridge: Bool = false,
                blobCache: URL? = nil, snapshot: Snapshot? = nil, snapshotIsSaved: Bool = false, now: (@Sendable () -> Int64)? = nil) {
        self.keys = keys
        self.blobCache = blobCache
        self.encrypted = encrypted && keys != nil
        self.transports = transports
        self.bridge = bridge
        self.clock = now ?? { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
        // Loaded from a LocalDatabase: it already holds all of this, so the first save needn't rewrite it.
        needsRewrite = !snapshotIsSaved
        if let snapshot {
            journal = Journal(state: snapshot.journal, pending: snapshot.pending, now: now)
            applied = Set(snapshot.applied)
            unpushed = snapshot.unpushed.mapValues(Set.init)
            unpushedBlobs = (snapshot.unpushedBlobs ?? [:]).mapValues(Set.init)
            bridgeBlobs = Set(snapshot.bridgeBlobs ?? [])
            checkpointCheckedAt = snapshot.checkpointCheckedAt
            if let base = snapshot.base {
                checkpoint = base
                store.useBase(base.base)
            }
            store.apply(snapshot.ops)
            store.apply(snapshot.pending)
            // Rebuild the outbox for anything not yet pushed from this device's own ops.
            let mine = snapshot.ops.filter { $0.device == device }
            for key in unpushed.values.reduce(into: Set<String>(), { $0.formUnion($1) }) {
                let parts = key.split(separator: "/")
                guard parts.count == 2, let first = Int(parts[1]) else { continue }
                let run = mine.filter { $0.seq >= first }.sorted { $0.seq < $1.seq }
                var batch: [Op] = []
                for op in run where batch.isEmpty || op.seq == batch.last!.seq + 1 { batch.append(op) }
                if let seg = try? Segment(device: device, ops: batch) { outbox[key] = seg }
            }
        } else {
            journal = Journal(state: .init(device: device), now: now)
        }
    }

    public var device: String { journal.device }
    /// Local edits not yet cut into segments, so the app can push them soon after the user types.
    public var hasUnsentChanges: Bool { !journal.pending.isEmpty }
    public var records: [Record] { store.visible }
    /// The records of one kind (not deleted): much cheaper than filtering `records`.
    public func records(kind: String) -> [Record] { store.visible(kind: kind) }
    /// Strokes and elements on an item (not deleted).
    public func ink(on itemId: String) -> [Record] { store.ink(on: itemId) }
    public func record(_ id: String) -> Record? { store.record(id) }

    public func addTransport(_ t: any SyncTransport) { transports.append(t) }

    public func snapshot() -> Snapshot {
        Snapshot(journal: journal.state, pending: journal.pending, unpushed: unpushed.mapValues { Array($0).sorted() },
                 applied: Array(applied).sorted(), ops: store.opsAfterBase, unpushedBlobs: unpushedBlobs.mapValues { Array($0).sorted() },
                 bridgeBlobs: bridgeBlobs.isEmpty ? nil : bridgeBlobs.sorted(), base: checkpoint, checkpointCheckedAt: checkpointCheckedAt)
    }

    // MARK: Saving a little at a time (LocalDatabase)

    private var localState: LocalState {
        LocalState(journal: journal.state, pending: journal.pending, unpushed: unpushed.mapValues { Array($0).sorted() },
                   unpushedBlobs: unpushedBlobs.mapValues { Array($0).sorted() }, bridgeBlobs: bridgeBlobs.sorted(),
                   checkpointCheckedAt: checkpointCheckedAt)
    }

    /// What to write since the last save; the first save (or one after `saveFailed`) is everything.
    public func takeSaveDelta() -> SaveDelta {
        let delta: SaveDelta
        if needsRewrite {
            delta = SaveDelta(state: localState, newOps: store.opsAfterBase, newApplied: Array(applied).sorted(), base: checkpoint,
                              baseChanged: true, rewrite: true)
        } else {
            delta = SaveDelta(state: localState, newOps: unsavedOps.filter { !store.isCovered($0) }, newApplied: unsavedApplied,
                              base: baseChanged ? checkpoint : nil, baseChanged: baseChanged, rewrite: false)
        }
        unsavedOps = []
        unsavedApplied = []
        baseChanged = false
        needsRewrite = false
        return delta
    }

    /// The local copy is already what this engine holds (it was just loaded from it).
    public func markSaved() {
        unsavedOps = []
        unsavedApplied = []
        baseChanged = false
        needsRewrite = false
    }

    /// A save didn't make it: the next one writes everything.
    public func saveFailed() { needsRewrite = true }

    /// Hears that records changed (call `records` or `records(kind:)` for what's there now).
    @discardableResult
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        guard !observers.isEmpty, holding == 0 else { if holding > 0 { heldChanges = true }; return }
        for cb in observers.values { cb() }
    }

    private var holding = 0
    private var heldChanges = false

    /// Many edits at once (an import): between `hold()` and `release()` observers hear nothing, then
    /// once (each write telling the app to refresh made big imports crawl).
    public func hold() { holding += 1 }

    public func release() {
        holding = max(0, holding - 1)
        if holding == 0, heldChanges { heldChanges = false; notify() }
    }

    // MARK: Local edits

    @discardableResult
    public func set(_ fields: [String: JSONValue], record: String, kind: String? = nil) -> Op {
        let op = journal.set(fields, record: record, kind: kind)
        unsavedOps += store.apply([op])
        notify()
        return op
    }

    @discardableResult
    public func editText(_ field: String, value: String, record: String, kind: String? = nil) -> Op? {
        let previous = store.record(record)?.texts[field] ?? ""
        guard previous != value else { return nil }
        let op = journal.text(field, value: value, previous: previous, record: record, kind: kind)
        unsavedOps += store.apply([op])
        notify()
        return op
    }

    /// Deletes a record, keeping its kind (a delete with none would name an unknown id an item).
    public func delete(_ record: String) { set(["_deleted": true], record: record, kind: store.record(record)?.kind) }

    // MARK: Sync

    public func sync() async -> Report {
        var report = Report()
        // 0. A device with nothing yet starts from the newest checkpoint instead of every op.
        //    (A device bridging iCloud and the relay fetches every segment anyway, to copy them across.)
        if !bridge, store.opCount == 0, store.base == nil, applied.isEmpty { await loadCheckpoint(&report) }
        // 1. Cut pending ops into segments and queue them for every transport.
        do {
            for segment in try journal.takeSegments() {
                let key = SegmentRef(device: segment.device, first: segment.first, last: segment.last).key
                outbox[key] = segment
                if applied.insert(key).inserted { unsavedApplied.append(key) }
                for t in transports { unpushed[t.name, default: []].insert(key) }
            }
        } catch {
            report.errors.append("journal: \(error)")
        }

        // 2. Push (attachments first, so a record never arrives before its file).
        for t in transports {
            for id in (unpushedBlobs[t.name] ?? []).sorted() {
                do {
                    if let data = cachedBlob(id), !(try await t.hasBlob(id)) { try await t.pushBlob(id, data: data) }
                    unpushedBlobs[t.name]?.remove(id)
                } catch {
                    report.errors.append("\(t.name) blob \(id.prefix(8)): \(error)")
                }
            }
        }
        for t in transports {
            for key in (unpushed[t.name] ?? []).sorted() {
                guard let segment = outbox[key] else { unpushed[t.name]?.remove(key); continue }
                do {
                    try await t.pushSegment(SegmentRef(device: segment.device, first: segment.first, last: segment.last), data: encode(segment))
                    unpushed[t.name]?.remove(key)
                    report.pushed += 1
                } catch {
                    report.errors.append("\(t.name) push \(key): \(error)")
                }
            }
        }
        let stillNeeded = unpushed.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        outbox = outbox.filter { stillNeeded.contains($0.key) }

        // 3. Pull.
        var fetched: [(SegmentRef, Data, String)] = []
        for t in transports {
            do {
                var ok = true
                for ref in try await t.listSegments() where !applied.contains(ref.key) && ref.device != device {
                    // Already inside the checkpoint: no need to download it.
                    if !bridge, let base = store.base, Checkpoint.covers(base.covers, device: ref.device, first: ref.first, last: ref.last) {
                        continue
                    }
                    do {
                        let data = try await t.fetchSegment(ref)
                        let segment = try Segment.decodeAny(data, device: ref.device, keys: keys)
                        for op in segment.ops { journal.observe(op.hlc) }
                        unsavedOps += store.apply(segment.ops)
                        if applied.insert(ref.key).inserted { unsavedApplied.append(ref.key) }
                        fetched.append((ref, data, t.name))
                        report.pulled += 1
                    } catch {
                        ok = false
                        report.errors.append("\(t.name) pull \(ref.key): \(error)")
                    }
                }
                if ok, let relay = t as? RelayTransport { relay.commitCursor() }
            } catch {
                report.errors.append("\(t.name) list: \(error)")
            }
        }

        // 4. Bridge: give every transport the segments it lacks (identical bytes, idempotent), and
        //    the attachments those segments point at, so a phone on iCloud only can open a file
        //    the website uploaded to the relay (and the other way round).
        if bridge {
            for (ref, data, source) in fetched {
                for t in transports where t.name != source {
                    do { try await t.pushSegment(ref, data: data) } catch { report.errors.append("bridge \(t.name) \(ref.key): \(error)") }
                }
            }
            for (ref, _, _) in fetched {
                for op in store.allOps where op.device == ref.device && op.seq >= ref.first && op.seq <= ref.last {
                    bridgeBlobs.formUnion(Self.attachmentIds(in: op))
                }
            }
            await copyBridgeBlobs(&report)
        }
        if report.pulled > 0 || report.loadedCheckpoint != nil { notify() }
        let nothingUnpushed = journal.pending.isEmpty && unpushed.values.allSatisfy(\.isEmpty)
        if report.errors.isEmpty, nothingUnpushed { await writeCheckpointIfDue(&report) }
        return report
    }

    // MARK: Checkpoints (PROTOCOL.md §3 "Checkpoints")

    private var checkpointTransports: [any CheckpointTransport] { transports.compactMap { $0 as? any CheckpointTransport } }

    /// Starts from the newest checkpoint any transport has (and this device can read).
    private func loadCheckpoint(_ report: inout Report) async {
        guard encrypted, let keys else { return }
        for t in checkpointTransports {
            let list: [CheckpointInfo]
            do { list = try await t.listCheckpoints() } catch { continue } // an older relay: pull every op
            for info in list.prefix(2) {
                do {
                    let cp = try Checkpoint.open(try await t.fetchCheckpoint(info.id), keys: keys)
                    adopt(cp, id: info.id)
                    report.loadedCheckpoint = info.id
                    return
                } catch {
                    report.errors.append("\(t.name) checkpoint \(info.id): \(error)")
                }
            }
        }
    }

    /// Uses a checkpoint as the store's base (and the local copy's, from the next save).
    @discardableResult
    private func adopt(_ cp: Checkpoint, id: String) -> Bool {
        var base = cp.base
        base.id = id
        guard store.useBase(base) else { return false }
        for op in cp.texts { journal.observe(op.hlc) }
        journal.observe(cp.frontier)
        // This device's own ops are in it (its local copy was lost): number new ones after them.
        journal.skip(past: base.lastCovered(device))
        if let cursor = cp.cursor {
            for t in transports { (t as? RelayTransport)?.advanceCursor(to: cursor) }
        }
        checkpoint = cp
        baseChanged = true
        return true
    }

    /// Writes a checkpoint when enough ops have piled up since the last one and the newest anywhere is
    /// a day old, then uses it locally too. Call only with nothing unpushed.
    private func writeCheckpointIfDue(_ report: inout Report, force: Bool = false) async {
        guard encrypted, let keys, !checkpointTransports.isEmpty else { return }
        let since = store.opCount - (store.base?.texts.count ?? 0)
        let now = Double(clock())
        if !force {
            guard since >= Self.checkpointAfterOps else { return }
            guard now - (checkpointCheckedAt ?? 0) >= Self.checkpointCheckEvery else { return }
        }
        checkpointCheckedAt = now
        var newest: Double = 0
        for t in checkpointTransports {
            if let first = try? await t.listCheckpoints().first { newest = max(newest, first.createdAt) }
        }
        if !force, now - newest < Self.checkpointMinAge { return }
        let relayCursor = transports.compactMap { ($0 as? RelayTransport)?.currentCursor }.first
        let cp = Checkpoint.make(from: store, cursor: relayCursor, device: device, createdAt: Date(timeIntervalSince1970: now / 1000))
        let data: Data
        do { data = try cp.sealed(with: keys) } catch { report.errors.append("checkpoint: \(error)"); return }
        let id = UUID().uuidString.lowercased()
        var wrote = false
        for t in checkpointTransports {
            let tid = t is FolderTransport ? "\(device)/\(id)" : id
            do {
                try await t.pushCheckpoint(tid, data: data)
                wrote = true
            } catch {
                report.errors.append("\(t.name) checkpoint: \(error)")
            }
        }
        if wrote, adopt(cp, id: id) { report.wroteCheckpoint = id }
    }

    /// Writes a checkpoint now, whatever the thresholds (tests, and "Make a checkpoint" in the app).
    public func writeCheckpoint() async -> Report {
        var report = Report()
        guard journal.pending.isEmpty, unpushed.values.allSatisfy(\.isEmpty) else {
            report.errors.append("checkpoint: sync first")
            return report
        }
        await writeCheckpointIfDue(&report, force: true)
        return report
    }

    /// The checkpoint the store starts from, if any.
    public var checkpointId: String? { store.base?.id }

    /// Attachment ids an op refers to: any `{id, mime}` object in its fields (attachments,
    /// thumbnails, file versions, clip images).
    static func attachmentIds(in op: Op) -> Set<String> {
        var out: Set<String> = []
        func visit(_ v: JSONValue) {
            switch v {
            case .object(let o):
                if let id = o["id"]?.string, o["mime"]?.string != nil { out.insert(id) }
                for child in o.values { visit(child) }
            case .array(let a): for child in a { visit(child) }
            default: break
            }
        }
        for value in (op.fields ?? [:]).values { visit(value) }
        return out
    }

    private func copyBridgeBlobs(_ report: inout Report) async {
        for id in bridgeBlobs.sorted().prefix(Self.bridgeBlobsPerSync) {
            var missing: [any SyncTransport] = []
            var bytes: Data?
            for t in transports {
                // A folder can say whether it has the file; the relay can only be asked for it.
                let has = t is FolderTransport ? (try? await t.hasBlob(id)) == true : nil
                if has == false { missing.append(t); continue }
                if bytes == nil, let data = try? await t.fetchBlob(id) { bytes = data; continue }
                if has == nil { missing.append(t) }
            }
            guard let bytes else { bridgeBlobs.remove(id); continue } // nobody has it (yet): the uploader retries
            var ok = true
            for t in missing {
                do { try await t.pushBlob(id, data: bytes) } catch { ok = false; report.errors.append("bridge \(t.name) blob \(id.prefix(8)): \(error)") }
            }
            if ok { bridgeBlobs.remove(id) }
        }
    }

    private func encode(_ segment: Segment) throws -> Data {
        if encrypted, let keys { return try segment.encrypted(with: keys) }
        return try segment.plaintext()
    }

    // MARK: Attachments

    /// Encrypts an attachment, keeps it locally and uploads it now or on the next sync; returns its id.
    public func storeBlob(_ data: Data) async throws -> String {
        let id = keys?.blobId(for: data) ?? data.sha256Hex
        if cachedBlob(id) == nil {
            let stored = try encrypted ? TRV1.encrypt(data, key: keys!.blobKey) : data
            try cacheBlob(id, stored)
        }
        for t in transports {
            do {
                if !(try await t.hasBlob(id)), let stored = cachedBlob(id) { try await t.pushBlob(id, data: stored) }
            } catch {
                unpushedBlobs[t.name, default: []].insert(id)
            }
        }
        return id
    }

    /// Reading and decrypting happen off the engine, so opening a big file never holds up syncing,
    /// search or other files.
    public nonisolated func loadBlob(_ id: String) async throws -> Data {
        let keys = self.keys
        let file = blobCache?.appendingPathComponent(id)
        var stored: Data? = if let file {
            await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
        } else {
            await memoryBlob(id)
        }
        if stored == nil { stored = try await fetchAndCacheBlob(id) }
        let data = stored!
        return try await Task.detached(priority: .userInitiated) {
            if TRV1.mode(of: data) != nil, let keys { return try TRV1.decrypt(data, key: keys.blobKey) }
            return data
        }.value
    }

    private func memoryBlob(_ id: String) -> Data? { memoryBlobs[id] }

    private func fetchAndCacheBlob(_ id: String) async throws -> Data {
        if let cached = cachedBlob(id) { return cached }
        var lastError: Error = TransportError.notFound
        for t in transports {
            do {
                let fetched = try await t.fetchBlob(id)
                try? cacheBlob(id, fetched)
                return fetched
            } catch { lastError = error }
        }
        throw lastError
    }

    private func cachedBlob(_ id: String) -> Data? {
        guard let blobCache else { return memoryBlobs[id] }
        return try? Data(contentsOf: blobCache.appendingPathComponent(id))
    }

    private func cacheBlob(_ id: String, _ data: Data) throws {
        guard let blobCache else { memoryBlobs[id] = data; return }
        try FileManager.default.createDirectory(at: blobCache, withIntermediateDirectories: true)
        try data.write(to: blobCache.appendingPathComponent(id), options: .atomic)
    }
}
