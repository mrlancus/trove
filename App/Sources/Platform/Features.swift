import Foundation

/// Features hidden from the app, not deleted (docs/plans/learn-pivot-plan.md §3). Constants, not settings:
/// nothing to sync or migrate. Switching one back on is one line here plus a build. Every entry point and
/// every background start checks its flag.
///
/// Tests turn them back on with the launch argument `-TroveFeatures all` (or a comma list such as
/// `-TroveFeatures graph,obsidian`), read once at start, so the code of hidden features keeps being tested.
enum Features {
    /// The Obsidian-style graph: Connections, the graph on items, the clipboard Map.
    /// (Backlinks, `[[links]]` and "maybe related" stay; they don't need it.)
    static let graph = on("graph", shipped: false)
    /// Two-way sync with an Obsidian vault folder (Settings → Other apps). The one-off import stays.
    static let obsidian = on("obsidian", shipped: false)
    /// The relay's GitHub stars bridge.
    static let githubBridge = on("githubBridge", shipped: false)
    /// The relay's Telegram bot bridge (plan §10 Q2).
    static let telegramBridge = on("telegramBridge", shipped: false)

    /// Bridge kinds whose feature is hidden on this build (paused on the relay, `BridgePause`).
    static var hiddenBridgeKinds: Set<String> {
        var out = Set<String>()
        if !githubBridge { out.insert("github") }
        if !telegramBridge { out.insert("telegram") }
        return out
    }

    /// The names given with `-TroveFeatures`, read once.
    private static let overrides: Set<String> = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-TroveFeatures"), i + 1 < args.count else { return [] }
        return Set(args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }()

    private static func on(_ name: String, shipped: Bool) -> Bool {
        shipped || overrides.contains("all") || overrides.contains(name)
    }
}
