import LocalAuthentication
import SwiftUI

/// App lock (MASTER_PLAN S3, first part): Face ID, Touch ID or the device passcode to open Trove,
/// after it's been away for a while, with the window covered in the app switcher. Per device.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "lock.enabled"); if !enabled { locked = false } } }
    /// Minutes away before it locks again (0 = every time).
    var after: Int { didSet { UserDefaults.standard.set(after, forKey: "lock.after") } }
    private(set) var locked: Bool
    private var leftAt: Date?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "lock.enabled")
        after = UserDefaults.standard.object(forKey: "lock.after") as? Int ?? 5
        locked = UserDefaults.standard.bool(forKey: "lock.enabled")
    }

    func wentAway() { leftAt = Date() }

    func cameBack() {
        guard enabled else { return }
        if let leftAt, Date().timeIntervalSince(leftAt) >= Double(after * 60) { locked = true }
    }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { locked = false; return }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open Trove")) == true { locked = false }
    }
}

/// Covers the window while locked (and in the app switcher while the lock is on).
struct LockCover: ViewModifier {
    @Environment(\.scenePhase) private var phase
    let lock = AppLock.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if lock.enabled && (lock.locked || phase != .active) {
                    ZStack {
                        Rectangle().fill(.regularMaterial).ignoresSafeArea()
                        VStack(spacing: 16) {
                            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                            if lock.locked { Button("Unlock Trove") { Task { await lock.unlock() } }.buttonStyle(.borderedProminent) }
                        }
                    }
                    .task { if lock.locked, phase == .active { await lock.unlock() } }
                }
            }
            .onChange(of: phase) { _, p in
                if p == .background { lock.wentAway() }
                if p == .active { lock.cameBack() }
            }
    }
}

struct AppLockSection: View {
    @Bindable var lock = AppLock.shared
    var body: some View {
        Section {
            Toggle("Lock Trove", isOn: $lock.enabled)
            if lock.enabled {
                Picker("Lock after", selection: $lock.after) {
                    Text("Every time").tag(0)
                    Text("1 minute away").tag(1)
                    Text("5 minutes away").tag(5)
                    Text("An hour away").tag(60)
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            FormFooter("Face ID, Touch ID or your passcode to open Trove on this device; the window is hidden in the app switcher.")
        }
    }
}
