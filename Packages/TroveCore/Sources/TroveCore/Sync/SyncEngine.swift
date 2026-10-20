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
    }

    public struct Report: Sendable, Equatable {
        public var pushed = 0
        public var pulled = 0
        public var errors: [String] = []
    }

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
    private var observers: [UUID: @Sendable ([Record]) -> Void] = [:]
    /// Encrypted attachment bytes kept on this device (directory, or memory when nil).
    private let blobCache: URL?
    private var memoryBlobs: [String: Data] = [:]
    private var unpushedBlobs: [String: Set<String>] = [:]
    /// Attachments other devices put on one transport that a bridging device still has to copy to the rest.
    private var bridgeBlobs: Set<String> = []
    static let bridgeBlobsPerSync = 40

    public init(device: String, keys: VaultKeys?, encrypted: Bool = true, transports: [any SyncTransport] = [], bridge: Bool = false,
                blobCache: URL? = nil, snapshot: Snapshot? = nil, now: (@Sendable () -> Int64)? = nil) {
        self.keys = keys
        self.blobCache = blobCache
        self.encrypted = encrypted && keys != nil
        self.transports = transports
        self.bridge = bridge
        if let snapshot {
            journal = Journal(state: snapshot.journal, pending: snapshot.pending, now: now)
            applied = Set(snapshot.applied)
            unpushed = snapshot.unpushed.mapValues(Set.init)
            unpushedBlobs = (snapshot.unpushedBlobs ?? [:]).mapValues(Set.init)
            bridgeBlobs = Set(snapshot.bridgeBlobs ?? [])
            store.apply(snapshot.ops)
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
    public func record(_ id: String) -> Record? { store.record(id) }

    public func addTransport(_ t: any SyncTransport) { transports.append(t) }

    public func snapshot() -> Snapshot {
        Snapshot(journal: journal.state, pending: journal.pending, unpushed: unpushed.mapValues { Array($0).sorted() },
                 applied: Array(applied).sorted(), ops: store.allOps, unpushedBlobs: unpushedBlobs.mapValues { Array($0).sorted() },
                 bridgeBlobs: bridgeBlobs.isEmpty ? nil : bridgeBlobs.sorted())
    }

    @discardableResult
    public func observe(_ callback: @escaping @Sendable ([Record]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        let visible = store.visible
        for cb in observers.values { cb(visible) }
    }

    // MARK: Local edits

    @discardableResult
    public func set(_ fields: [String: JSONValue], record: String, kind: String? = nil) -> Op {
        let op = journal.set(fields, record: record, kind: kind)
        store.apply([op])
        notify()
        return op
    }

    @discardableResult
    public func editText(_ field: String, value: String, record: String, kind: String? = nil) -> Op? {
        let previous = store.record(record)?.texts[field] ?? ""
        guard previous != value else { return nil }
        let op = journal.text(field, value: value, previous: previous, record: record, kind: kind)
        store.apply([op])
        notify()
        return op
    }

    public func delete(_ record: String) { set(["_deleted": true], record: record) }

    // MARK: Sync

    public func sync() async -> Report {
        var report = Report()
        // 1. Cut pending ops into segments and queue them for every transport.
        do {
            for segment in try journal.takeSegments() {
                let key = SegmentRef(device: segment.device, first: segment.first, last: segment.last).key
                outbox[key] = segment
                applied.insert(key)
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
                    do {
                        let data = try await t.fetchSegment(ref)
                        let segment = try Segment.decodeAny(data, device: ref.device, keys: keys)
                        for op in segment.ops { journal.observe(op.hlc) }
                        store.apply(segment.ops)
                        applied.insert(ref.key)
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
        if report.pulled > 0 { notify() }
        return report
    }

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

    public func loadBlob(_ id: String) async throws -> Data {
        var stored = cachedBlob(id)
        if stored == nil {
            var lastError: Error = TransportError.notFound
            for t in transports {
                do { stored = try await t.fetchBlob(id); break } catch { lastError = error }
            }
            guard let fetched = stored else { throw lastError }
            try? cacheBlob(id, fetched)
        }
        let data = stored!
        if TRV1.mode(of: data) != nil, let keys { return try TRV1.decrypt(data, key: keys.blobKey) }
        return data
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
