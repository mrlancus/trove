import SwiftUI
import TroveCore
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// "Save to Trove" in the share sheet (iPhone, iPad and Mac). Seals what you share to the vault's
/// public key and posts it to the relay inbox, or leaves it in the App Group for the app.
struct ShareForm: View {
    let items: [NSExtensionItem]
    let done: (Bool) -> Void
    @State private var preview = "Loading…"
    @State private var note = ""
    @State private var status: String?
    @State private var envelopes: [InboxEnvelope] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Save to Trove", systemImage: "shippingbox.fill").font(.headline).foregroundStyle(.orange)
                Spacer()
                Button("Cancel") { done(false) }
            }
            Text(preview).font(.callout).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            TextField("Add a note… #tags work", text: $note, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Button { save() } label: { Text("Save").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(envelopes.isEmpty)
        }
        .padding(20)
        .task { await load() }
    }

    private func load() async {
        var out: [InboxEnvelope] = []
        var titles: [String] = []
        let title = items.first?.attributedContentText?.string
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL, let data = try? Data(contentsOf: url) {
                        out.append(CaptureDrop.file(data, name: url.lastPathComponent, mime: Self.mime(url)))
                        titles.append(url.lastPathComponent)
                    } else {
                        out.append(CaptureDrop.link(url, title: title))
                        titles.append(url.absoluteString)
                    }
                } else if let (data, name, mime) = await Self.loadFile(provider) {
                    out.append(CaptureDrop.file(data, name: name, mime: mime))
                    titles.append(name)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    out.append(CaptureDrop.text(text, title: title))
                    titles.append(text)
                }
            }
        }
        envelopes = out
        preview = titles.isEmpty ? "Nothing Trove can save here." : titles.joined(separator: "\n")
    }

    private func save() {
        status = "Encrypting…"
        Task {
            do {
                var routes = Set<String>()
                for var envelope in envelopes {
                    if !note.isEmpty {
                        if envelope.header.mime?.hasPrefix("text/") == true {
                            envelope.body = Data(([String(decoding: envelope.body, as: UTF8.self), note].filter { !$0.isEmpty }).joined(separator: "\n\n").utf8)
                        } else {
                            routes.insert(try await CaptureDrop.send(CaptureDrop.text(note, title: envelope.header.title)))
                        }
                    }
                    routes.insert(try await CaptureDrop.send(envelope))
                }
                status = routes.contains("local") ? "Saved. It'll appear when you next open Trove." : "Saved ✓"
                try? await Task.sleep(for: .milliseconds(600))
                done(true)
            } catch {
                status = error.localizedDescription
            }
        }
    }

    nonisolated static func loadFile(_ provider: NSItemProvider) async -> (Data, String, String)? {
        let suggested = provider.suggestedName
        for type in [UTType.pdf, .image, .movie, .audio, UTType(filenameExtension: "md") ?? .plainText, .data] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if type == .plainText { continue }
            let result: (Data, String, String)? = await withCheckedContinuation { c in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { c.resume(returning: nil); return }
                    c.resume(returning: (data, suggested.map { $0 + "." + (url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "bin") : url.pathExtension) } ?? url.lastPathComponent,
                                         type.preferredMIMEType ?? mime(url)))
                }
            }
            if let result { return result }
        }
        return nil
    }

    nonisolated static func mime(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

#if canImport(UIKit)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let host = UIHostingController(rootView: ShareForm(items: items) { [weak self] saved in
            if saved { self?.extensionContext?.completeRequest(returningItems: nil) }
            else { self?.extensionContext?.cancelRequest(withError: NSError(domain: "Trove", code: 0)) }
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}
#else
final class ShareViewController: NSViewController {
    override func loadView() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let host = NSHostingView(rootView: ShareForm(items: items) { [weak self] saved in
            if saved { self?.extensionContext?.completeRequest(returningItems: nil) }
            else { self?.extensionContext?.cancelRequest(withError: NSError(domain: "Trove", code: 0)) }
        }.frame(width: 420))
        view = host
    }
}
#endif
