import Foundation

/// Strips tracking parameters and normalises URLs so the same page saved twice de-duplicates.
public enum URLCleaner {
    static let trackingPrefixes = ["utm_", "mc_", "pk_", "hsa_", "_hs", "vero_"]
    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "igshid", "igsh",
        "si", "ref_src", "ref_url", "s_cid", "cmpid", "_ga", "_gl", "spm", "share_id", "feature", "mkt_tok", "oly_anon_id", "oly_enc_id",
    ]
    /// `si` and `feature` are tracking on YouTube/Spotify but meaningful elsewhere, so only strip them there.
    static let hostScopedNames: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp"], "youtu.be": ["si", "feature"], "open.spotify.com": ["si"],
    ]
    static let globalOnlyNames = trackingNames.subtracting(["si", "feature"])

    public static func clean(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return url }
        c.scheme = scheme
        c.host = c.host?.lowercased()
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        let host = (c.host ?? "").replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "m.", with: "", options: .anchored)
        let scoped = hostScopedNames.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        if let items = c.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                if globalOnlyNames.contains(name) || scoped.contains(name) { return false }
                return !trackingPrefixes.contains { name.hasPrefix($0) }
            }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        if c.fragment?.hasPrefix(":~:text=") == true { c.fragment = nil }
        if c.path.isEmpty { c.path = "/" }
        return c.url ?? url
    }

    /// Key used to spot duplicates: cleaned URL without scheme, `www.` or trailing slash.
    public static func dedupeKey(_ url: URL) -> String {
        let cleaned = clean(url)
        var s = cleaned.absoluteString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
