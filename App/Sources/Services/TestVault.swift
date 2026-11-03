import Foundation
import TroveCore

#if DEBUG
/// For UI and performance tests only (docs/PERF_AUDIT.md step 0): launched with `-TroveTestVault small`
/// (or `tiny`, `full`), Trove opens a trove-gen vault in its own folder instead of yours. Its keys live
/// in memory, never in the Keychain, and it has no relay. Debug builds only: release builds never
/// look at the argument.
enum TestVault {
    static var size: TroveGen.Size? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-TroveTestVault"), i + 1 < args.count else { return nil }
        return TroveGen.Size.named(args[i + 1])
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trove-TestVault-\(size?.items ?? 0)", isDirectory: true)
    }

    /// Writes the vault the first time (a few seconds for `small`), then returns its config.
    static func prepare(_ size: TroveGen.Size, in support: URL) -> VaultConfig {
        let folder = support.appendingPathComponent("vault", isDirectory: true)
        let done = DispatchSemaphore(value: 0)
        let result = Box()
        Task.detached(priority: .userInitiated) {
            result.vaultId = (try? await TroveGen.writeFolderVault(at: folder, size)) ?? "trove-gen"
            done.signal()
        }
        done.wait()
        return VaultConfig(vaultId: result.vaultId, deviceId: "UITEST-DEVICE", encrypted: false, storage: .path(folder.path),
                           relay: nil, mirrorOwner: false)
    }

    private final class Box: @unchecked Sendable { var vaultId = "" }
}
#endif
