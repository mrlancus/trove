import SwiftUI

/// Settings → Appearance (docs/MASTER_PLAN.md D1b). Some people don't like Liquid Glass, so the
/// look is a choice, per device: Automatic (Liquid Glass on OS 26, Standard before that or with
/// Reduce Transparency), Liquid Glass, or Standard (solid, familiar bars and panels).
enum AppearanceStyle: String, CaseIterable, Identifiable {
    case automatic, glass, standard
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .glass: "Liquid Glass"
        case .standard: "Standard"
        }
    }
    static let key = "appearance.style"
}

enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Match the system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    static let key = "appearance.theme"
}

enum CardDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var label: String { self == .comfortable ? "Comfortable" : "Compact" }
    /// The smallest card width in the library grid.
    var minimumWidth: CGFloat { self == .comfortable ? 220 : 160 }
    static let key = "appearance.density"
}

/// Whether floating controls use Liquid Glass right now.
struct UsesGlassKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var usesGlass: Bool {
        get { self[UsesGlassKey.self] }
        set { self[UsesGlassKey.self] = newValue }
    }
}

/// Applied once at the root of every window: the theme, and whether the glass look is on.
struct AppearanceRoot: ViewModifier {
    @AppStorage(AppearanceStyle.key) private var style = AppearanceStyle.automatic.rawValue
    @AppStorage(AppearanceTheme.key) private var theme = AppearanceTheme.system.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var glassOn: Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else { return false }
        switch AppearanceStyle(rawValue: style) ?? .automatic {
        case .automatic: return !reduceTransparency
        case .glass: return true
        case .standard: return false
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.usesGlass, glassOn)
            .preferredColorScheme((AppearanceTheme(rawValue: theme) ?? .system).scheme)
            .modifier(StandardBars(on: !glassOn))
    }
}

/// Standard look: solid toolbar and tab bar backgrounds instead of the floating glass ones.
private struct StandardBars: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on {
            #if os(iOS)
            content
                .toolbarBackgroundVisibility(.visible, for: .navigationBar, .tabBar, .bottomBar)
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar, .tabBar, .bottomBar)
            #else
            content
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
            #endif
        } else {
            content
        }
    }
}

extension View {
    func troveAppearance() -> some View { modifier(AppearanceRoot()) }
}

struct AppearanceSection: View {
    @AppStorage(AppearanceStyle.key) private var style = AppearanceStyle.automatic.rawValue
    @AppStorage(AppearanceTheme.key) private var theme = AppearanceTheme.system.rawValue
    @AppStorage(CardDensity.key) private var density = CardDensity.comfortable.rawValue

    var body: some View {
        Section {
            Picker("Style", selection: $style) {
                ForEach(AppearanceStyle.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Theme", selection: $theme) {
                ForEach(AppearanceTheme.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Cards", selection: $density) {
                ForEach(CardDensity.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } header: {
            Text("Appearance")
        } footer: {
            FormFooter("Liquid Glass: controls float over your notes as see-through panels (iOS 26 and macOS 26). Standard: solid bars and panels, the familiar look, and a little lighter on the battery. Automatic uses Liquid Glass where the system has it, unless Reduce Transparency is on. Only on this device.")
        }
    }
}
