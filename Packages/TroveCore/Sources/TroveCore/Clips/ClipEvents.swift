import Foundation

/// One copy or paste of a clip (PROTOCOL.md §8 "Copy and paste events"), its own record so devices
/// never overwrite each other's. core/clipmap.js is the same; both check Fixtures/clip-events.json.
public struct ClipEvent: Identifiable, Hashable, Sendable {
    public static let kind = "clipEvent"

    public enum Kind: String, Sendable { case copy, paste, use }

    /// Where it happened: the device's location, never an IP address.
    public struct Place: Hashable, Sendable {
        public var lat: Double
        public var lon: Double
        public var accuracy: Double?
        public var name: String?
        public var city: String?
        public init(lat: Double, lon: Double, accuracy: Double? = nil, name: String? = nil, city: String? = nil) {
            self.lat = lat; self.lon = lon; self.accuracy = accuracy; self.name = name; self.city = city
        }

        var json: JSONValue {
            var o: [String: JSONValue] = ["lat": .number((lat * 1e5).rounded() / 1e5), "lon": .number((lon * 1e5).rounded() / 1e5)]
            if let accuracy { o["accuracy"] = .number(accuracy.rounded()) }
            if let name, !name.isEmpty { o["name"] = .string(name) }
            if let city, !city.isEmpty { o["city"] = .string(city) }
            return .object(o)
        }

        /// Its key and label: its name, else its city with its rounded position (about 100 m).
        public var key: (key: String, label: String) {
            if let name, !name.isEmpty { return ("place:\(name.lowercased())", name) }
            let la = String(format: "%.3f", lat), lo = String(format: "%.3f", lon)
            if let city, !city.isEmpty { return ("place:\(la),\(lo)", "\(city) (\(la), \(lo))") }
            return ("place:\(la),\(lo)", "\(la), \(lo)")
        }
    }

    public let record: Record
    public init(_ record: Record) { self.record = record }

    public var id: String { record.id }
    public var clip: String? { record["clip"]?.string }
    public var type: Kind { Kind(rawValue: record["type"]?.string ?? "") ?? .copy }
    public var at: Date { record["at"]?.date ?? Date(timeIntervalSince1970: 0) }
    public var device: String? { record["device"]?.string }
    public var deviceName: String? { record["deviceName"]?.string }
    public var app: String? { record["app"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var bundle: String? { record["bundle"]?.string }
    public var url: String? { record["url"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var title: String? { record["title"]?.string }
    public var window: String? { record["window"]?.string }
    public var place: Place? {
        guard let o = record["place"]?.object, let lat = o["lat"]?.number, let lon = o["lon"]?.number, lat.isFinite, lon.isFinite else { return nil }
        return Place(lat: lat, lon: lon, accuracy: o["accuracy"]?.number, name: o["name"]?.string, city: o["city"]?.string)
    }

    /// Where a copy came from or a paste went: the site when there's a page, else the app.
    public var whereKey: (key: String, label: String)? { Self.appKey(app: app, url: url) }

    public static func appKey(app: String?, url: String?) -> (key: String, label: String)? {
        if let url, let host = URL(string: url)?.host, !host.isEmpty {
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return ("site:\(h)", h)
        }
        if let app, !app.isEmpty { return ("app:\(app.lowercased())", app) }
        return nil
    }
}

extension Library {
    /// Every copy and paste, or one clip's, oldest first.
    public func clipEvents(of clip: String? = nil) async -> [ClipEvent] {
        await engine.records.filter { $0.kind == ClipEvent.kind }.map(ClipEvent.init)
            .filter { $0.clip != nil && (clip == nil || $0.clip == clip) }
            .sorted { $0.at != $1.at ? $0.at < $1.at : $0.record.createdHLC < $1.record.createdHLC }
    }

    /// Records a copy, a paste into an app (`paste`) or a copy back from the history (`use`).
    @discardableResult
    public func recordClipEvent(_ clip: String, _ type: ClipEvent.Kind, app: String? = nil, bundle: String? = nil, url: String? = nil,
                                title: String? = nil, window: String? = nil, deviceName: String? = nil, place: ClipEvent.Place? = nil,
                                at: Date? = nil) async -> String {
        let id = newId()
        var fields: [String: JSONValue] = ["clip": .string(clip), "type": .string(type.rawValue), "at": JSONValue(at ?? now()),
                                           "device": .string(await engine.device)]
        for (k, v) in [("app", app), ("bundle", bundle), ("url", url), ("title", title), ("window", window), ("deviceName", deviceName)] {
            if let v, !v.isEmpty { fields[k] = .string(v) }
        }
        if let place, place.lat.isFinite, place.lon.isFinite { fields["place"] = place.json }
        await engine.set(fields, record: id, kind: ClipEvent.kind)
        return id
    }

    /// Fills in a place's name (a device that can look places up does it for events without one).
    public func nameClipEventPlace(_ id: String, name: String?, city: String?) async {
        guard let r = await engine.record(id), r.kind == ClipEvent.kind, var place = ClipEvent(r).place else { return }
        place.name = name ?? place.name
        place.city = city ?? place.city
        await engine.set(["place": place.json], record: id, kind: ClipEvent.kind)
    }

    /// A clip's connections to other clips and library items.
    public func setClipLinks(_ id: String, _ links: [String]) async {
        var seen = Set<String>()
        let clean = links.filter { $0 != id && seen.insert($0).inserted }
        await engine.set(["links": JSONValue(clean)], record: id, kind: "clip")
    }

    public func connectClip(_ id: String, to other: String) async {
        guard let c = await clip(id), !c.links.contains(other) else { return }
        await setClipLinks(id, c.links + [other])
    }

    public func disconnectClip(_ id: String, from other: String) async {
        guard let c = await clip(id) else { return }
        await setClipLinks(id, c.links.filter { $0 != other })
    }
}
