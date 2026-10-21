import SwiftUI
import TroveCore

/// Settings → Bridges (PROTOCOL.md §4 "Bridges"): add addresses, feeds, GitHub and Telegram, run by
/// the relay and adding to Trove through the sealed inbox. Same API as the website's bridges.js.
struct BridgesSection: View {
    @State private var showing = false

    var body: some View {
        Section {
            Button { showing = true } label: { Label("Bridges…", systemImage: "point.3.filled.connected.trianglepath.dotted") }
                .sheet(isPresented: $showing) { BridgesView() }
        } footer: {
            FormFooter("Bring things in from other places: an add address for Shortcuts and scripts, feeds, GitHub stars and a Telegram bot. Your relay can add to your vault, never read it.")
        }
    }
}

struct BridgesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bridges: [RelayClient.Bridge] = []
    @State private var error: String?
    @State private var feedURL = ""
    @State private var githubUser = ""
    @State private var githubToken = ""
    @State private var telegramToken = ""

    private var client: RelayClient? { model.vault.relayClient }

    var body: some View {
        NavigationStack {
            Form {
                if client == nil {
                    Section { Text("Bridges need the relay. Turn it on in Settings first.").foregroundStyle(.secondary) }
                } else {
                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                    webhookSection
                    feedSection
                    githubSection
                    telegramSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Bridges")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    // MARK: Sections

    private var webhookSection: some View {
        let hooks = bridges.filter { $0.kind == "webhook" }
        return Section {
            ForEach(hooks) { b in
                VStack(alignment: .leading, spacing: 6) {
                    Text(b.setting("name") ?? "Add address").font(.headline)
                    if let url = b.hookURL {
                        Text(url).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                        HStack {
                            Button("Copy") { copy(url) }
                            Button("New address") { act { try await $0.regenerateBridge(b.id) } }
                        }
                        .buttonStyle(.borderless)
                    }
                    BridgeRow(bridge: b, toggle: { on in act { try await $0.updateBridge(b.id, enabled: on) } }, remove: { remove(b) })
                }
            }
            Button("Make an add address") {
                act { try await $0.addBridge(kind: "webhook", settings: ["name": hooks.isEmpty ? "Add address" : "Add address \(hooks.count + 1)"]) }
            }
        } header: {
            Text("Add from anywhere")
        } footer: {
            FormFooter("Shortcuts, IFTTT, Zapier or a script can send a link or text to this address: JSON like {\"url\": …} or {\"text\": …, \"title\": …}, a form, or plain text. Anyone with it can add to Trove, so keep it to yourself.")
        }
    }

    private var feedSection: some View {
        let feeds = bridges.filter { $0.kind == "rss" }
        return Section {
            ForEach(feeds) { b in
                VStack(alignment: .leading, spacing: 6) {
                    Text(feedName(b)).font(.headline)
                    Text(b.setting("url") ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    BridgeRow(bridge: b, toggle: { on in act { try await $0.updateBridge(b.id, enabled: on) } }, remove: { remove(b) },
                              run: { act { try await $0.runBridge(b.id) } })
                }
            }
            HStack {
                TextField("https://example.com/feed.xml", text: $feedURL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Follow") {
                    let url = feedURL.trimmingCharacters(in: .whitespaces)
                    feedURL = ""
                    act { try await $0.addBridge(kind: "rss", settings: ["url": url]) }
                }
                .disabled(feedURL.isEmpty)
            }
        } header: {
            Text("Feeds")
        } footer: {
            FormFooter("New posts from RSS or Atom feeds arrive as links in Feeds, checked every couple of hours.")
        }
    }

    @ViewBuilder private var githubSection: some View {
        if let gh = bridges.first(where: { $0.kind == "github" }) {
            Section("GitHub") {
                Text(gh.setting("username") ?? "").font(.headline)
                Toggle("Starred repositories", isOn: Binding(get: { gh.flag("stars") }, set: { on in
                    act { try await $0.updateBridge(gh.id, settings: ["stars": on]) }
                }))
                Toggle("New releases of my own repositories", isOn: Binding(get: { gh.flag("releases") }, set: { on in
                    act { try await $0.updateBridge(gh.id, settings: ["releases": on]) }
                }))
                if gh.hasToken {
                    Button("Forget token") { act { try await $0.updateBridge(gh.id, token: "") } }
                }
                BridgeRow(bridge: gh, toggle: { on in act { try await $0.updateBridge(gh.id, enabled: on) } }, remove: { remove(gh) },
                          run: { act { try await $0.runBridge(gh.id) } })
            }
        } else {
            Section {
                TextField("GitHub username", text: $githubUser)
                SecureField("Token (optional)", text: $githubToken)
                Button("Connect") {
                    let user = githubUser.trimmingCharacters(in: .whitespaces)
                    let token = githubToken.trimmingCharacters(in: .whitespaces)
                    githubToken = ""
                    act { try await $0.addBridge(kind: "github", settings: ["username": user], token: token.isEmpty ? nil : token) }
                }
                .disabled(githubUser.isEmpty)
            } header: {
                Text("GitHub")
            } footer: {
                FormFooter("Starred repositories arrive as links with their description, language and topics. Public stars need no token; a fine-grained token with public access only just raises GitHub's limit.")
            }
        }
    }

    @ViewBuilder private var telegramSection: some View {
        if let tg = bridges.first(where: { $0.kind == "telegram" }) {
            Section("Telegram") {
                Text(tg.telegram?.bot.map { "@" + $0 } ?? "Your bot").font(.headline)
                if tg.telegram?.linked == true {
                    Text("Send it links, notes, photos or files and they're saved to Trove.").foregroundStyle(.secondary)
                } else if let link = tg.telegram?.linkURL, let url = URL(string: link) {
                    Link("Open your bot in Telegram and press Start", destination: url)
                }
                BridgeRow(bridge: tg, toggle: { on in act { try await $0.updateBridge(tg.id, enabled: on) } }, remove: { remove(tg) })
            }
        } else {
            Section {
                SecureField("Bot token from @BotFather", text: $telegramToken)
                Button("Connect") {
                    let token = telegramToken.trimmingCharacters(in: .whitespaces)
                    telegramToken = ""
                    act { try await $0.addBridge(kind: "telegram", token: token) }
                }
                .disabled(telegramToken.isEmpty)
            } header: {
                Text("Telegram")
            } footer: {
                FormFooter("In Telegram, message @BotFather, send /newbot and paste the token it gives you. Then press Start in your bot; only that chat can add to Trove.")
            }
        }
    }

    // MARK: Actions

    private func feedName(_ b: RelayClient.Bridge) -> String {
        if let name = b.setting("name"), !name.isEmpty { return name }
        if let title = b.title, !title.isEmpty { return title }
        return URL(string: b.setting("url") ?? "")?.host ?? "Feed"
    }

    private func load() async {
        guard let client else { return }
        do {
            bridges = try await client.bridges()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs a call that returns the changed bridge, then shows it.
    private func act(_ work: @escaping @Sendable (RelayClient) async throws -> RelayClient.Bridge) {
        guard let client else { return }
        Task {
            do {
                let changed = try await work(client)
                if let index = bridges.firstIndex(where: { $0.id == changed.id }) {
                    bridges[index] = changed
                } else {
                    bridges.append(changed)
                }
                error = nil
            } catch {
                self.error = Self.message(error)
            }
        }
    }

    private func remove(_ b: RelayClient.Bridge) {
        guard let client else { return }
        Task {
            do {
                try await client.deleteBridge(b.id)
                bridges.removeAll { $0.id == b.id }
            } catch {
                self.error = Self.message(error)
            }
        }
    }

    private func copy(_ text: String) { Pasteboard.copy(text) }

    /// The relay's `{"error": "…"}` text when there is one.
    private static func message(_ error: any Error) -> String {
        if case TransportError.http(_, let body) = error,
           let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["error"] as? String {
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return error.localizedDescription
    }
}

/// On/off, status and the common buttons for one bridge.
private struct BridgeRow: View {
    let bridge: RelayClient.Bridge
    let toggle: (Bool) -> Void
    let remove: () -> Void
    var run: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("On", isOn: Binding(get: { bridge.enabled }, set: { toggle($0) }))
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            if let problem = bridge.status.lastError {
                Text("Last problem: " + problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if let run { Button("Check now", action: run) }
                Spacer()
                Button("Remove", role: .destructive, action: remove)
            }
            .buttonStyle(.borderless)
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if !bridge.enabled { parts.append("Off") }
        if let last = bridge.status.lastRunAt {
            parts.append("Last run " + Date(timeIntervalSince1970: last / 1000).relative)
        }
        parts.append("\(bridge.status.itemsAdded) added")
        return parts.joined(separator: " · ")
    }
}
