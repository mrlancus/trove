#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Observation

/// Keeps the Mac app up to date from the "latest" GitHub release, so there's nothing to download
/// by hand. CI publishes `update.json` next to `Trove-macOS.zip`:
/// `{version, build, url, size, signature, notes}`. `signature` is Ed25519 over the zip's bytes,
/// made with the GitHub secret UPDATE_SIGNING_KEY. The app only installs a zip whose signature
/// matches the public key in Info.plist (`TroveUpdatePublicKey`).
///
/// Every build is signed with the same certificate (GitHub secret MAC_CERT_P12), so macOS sees
/// each update as the same app and keeps its permissions (Accessibility, Apple Events…).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Decodable, Sendable, Equatable {
        var version: String
        var build: Int
        var url: URL
        var size: Int?
        var signature: String
        var notes: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate, downloading(String), ready(String), failed(String)
    }

    static let feed = URL(string: "https://github.com/mrlancus/trove/releases/download/latest/update.json")!
    private(set) var state: State = .idle
    private(set) var lastChecked: Date?
    var automatic: Bool = UserDefaults.standard.object(forKey: "updates.automatic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "updates.automatic") }
    }
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var staged: (release: Release, app: URL)?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    private var publicKey: Curve25519.Signing.PublicKey? {
        (Bundle.main.object(forInfoDictionaryKey: "TroveUpdatePublicKey") as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }
    /// Builds from Xcode (build 1) never update themselves.
    var isEnabled: Bool { publicKey != nil && currentBuild > 1 }

    /// Checks shortly after launch, then every 6 hours, while automatic updates are on.
    func start() {
        guard timer == nil, isEnabled else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                if let self, self.automatic { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Looks for a newer build. Automatic checks download it and ask to restart; a check from the
    /// menu also says when you're up to date.
    func check(userInitiated: Bool) async {
        guard isEnabled else {
            if userInitiated { state = .failed("This copy of Trove was built by hand, so it doesn't update itself.") }
            return
        }
        if case .downloading = state { return }
        if let staged, staged.release.build > currentBuild { state = .ready(staged.release.version); offerRestart(staged.release); return }
        state = .checking
        do {
            var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noFeed }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastChecked = Date()
            guard release.build > currentBuild else { state = .upToDate; return }
            try await download(release)
            offerRestart(release)
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    private func download(_ release: Release) async throws {
        state = .downloading(release.version)
        let (file, _) = try await URLSession.shared.download(from: release.url)
        let zip = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let key = publicKey, let signature = Data(base64Encoded: release.signature),
              key.isValidSignature(signature, for: zip) else { throw UpdateError.badSignature }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TroveUpdate-\(release.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("Trove.zip")
        try zip.write(to: zipURL)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path])
        let app = dir.appendingPathComponent("Trove.app")
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp }
        staged = (release, app)
        state = .ready(release.version)
    }

    private func offerRestart(_ release: Release) {
        guard canInstall else { state = .ready(release.version); return } // Settings explains; no alert every 6 hours
        let alert = NSAlert()
        alert.messageText = "Trove \(release.version) is ready"
        alert.informativeText = (release.notes.map { $0 + "\n\n" } ?? "") + "Trove restarts to finish updating. Your vault and settings stay as they are."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { installAndRelaunch() }
    }

    /// Whether this account may replace the app where it's installed. A standard (non-admin)
    /// account can't change /Applications; an admin account installs the update for everyone.
    var canInstall: Bool {
        FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    /// Swaps the new app in once this one has quit, then opens it. The old app is only removed once
    /// the new one is fully copied; if anything fails it's put back as it was.
    func installAndRelaunch() {
        guard let staged else { return }
        guard canInstall else {
            state = .failed("This Mac account can't change the Applications folder. Update from an administrator account, and it updates for everyone.")
            return
        }
        let target = Bundle.main.bundleURL.path
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "\(target).old"
        if /bin/mv "\(target)" "\(target).old"; then
          if /usr/bin/ditto "\(staged.app.path)" "\(target)"; then
            /bin/rm -rf "\(target).old"
          else
            /bin/rm -rf "\(target)"; /bin/mv "\(target).old" "\(target)"
          fi
        fi
        /usr/bin/open "\(target)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Couldn't install the update: \(error.localizedDescription)")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        guard process.terminationStatus == 0 else { throw UpdateError.unpackFailed }
    }

    enum UpdateError: LocalizedError {
        case noFeed, badSignature, wrongApp, unpackFailed
        var errorDescription: String? {
            switch self {
            case .noFeed: "No update information yet. Updates start with the next build after the signing keys are added."
            case .badSignature: "The download isn't signed by Trove's key, so it wasn't installed."
            case .wrongApp: "The download wasn't Trove, so it wasn't installed."
            case .unpackFailed: "Couldn't unpack the update."
            }
        }
    }
}
#endif
