import SwiftUI
import UIKit

/// The Trove keyboard: your clipboard history in any app on iPhone and iPad. Tap a clip to type
/// it. It reads the recent clips the Trove app leaves in the App Group (it has no vault keys and
/// never uses the network).
final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = KeyboardView(
            clips: SharedConfig.loadKeyboardClips(),
            hasFullAccess: hasFullAccess,
            showsGlobe: needsInputModeSwitchKey,
            insert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() })
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 290),
        ])
        host.didMove(toParent: self)
        self.host = host
    }
}

struct KeyboardView: View {
    let clips: [SharedConfig.KeyboardClip]
    let hasFullAccess: Bool
    let showsGlobe: Bool
    let insert: @MainActor (String) -> Void
    let deleteBackward: @MainActor () -> Void
    let nextKeyboard: @MainActor () -> Void
    @State private var filter = "all"
    @State private var justInserted: String?

    private var shown: [SharedConfig.KeyboardClip] {
        let pinned = clips.filter(\.pinned), rest = clips.filter { !$0.pinned }
        switch filter {
        case "pinned": return pinned
        case "links": return clips.filter { $0.kind == "link" }
        case "text": return clips.filter { !["link", "code", "json"].contains($0.kind) }
        default: return pinned + rest
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach([("all", "Recent"), ("pinned", "Pinned"), ("links", "Links"), ("text", "Text")], id: \.0) { key, title in
                    Button { filter = key } label: {
                        Text(title).font(.footnote.weight(filter == key ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(filter == key ? Color.orange.opacity(0.2) : Color.clear, in: Capsule())
                            .foregroundStyle(filter == key ? Color.orange : Color.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 6)

            if !hasFullAccess && clips.isEmpty {
                message("Turn on Allow Full Access", "Settings → General → Keyboard → Keyboards → Trove. It only lets this keyboard read the clips Trove saved on this iPhone. It never sends anything.")
            } else if shown.isEmpty {
                message("Nothing here yet", "Copy on your Mac, or tap Paste in Trove's Clipboard screen, and your clips appear here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(shown) { clip in
                            Button {
                                insert(clip.text)
                                justInserted = clip.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .font(["code", "json"].contains(clip.kind) ? .caption.monospaced() : .callout)
                                        .lineLimit(3).multilineTextAlignment(.leading)
                                        .foregroundStyle(.primary)
                                    if let source = clip.source { Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                                .padding(8)
                                .background(justInserted == clip.id ? Color.orange.opacity(0.25) : Color(uiColor: .secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    if clip.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).padding(5) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            HStack(spacing: 6) {
                if showsGlobe {
                    key(Image(systemName: "globe")) { nextKeyboard() }
                }
                key(Text("space")) { insert(" ") }.frame(maxWidth: .infinity)
                key(Image(systemName: "delete.left")) { deleteBackward() }
                key(Image(systemName: "return")) { insert("\n") }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func key(_ label: some View, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            label.font(.body).frame(minWidth: 44, maxWidth: .infinity, minHeight: 40)
                .background(Color(uiColor: .systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }
}
