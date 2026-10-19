import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TroveCore

/// End-to-end against a running relay: `cd server && npx wrangler dev --local`, then
/// `TROVE_RELAY_URL=http://127.0.0.1:8787 swift test --filter RelayIntegration`.
/// Skipped when the variable isn't set.
@Suite struct RelayIntegrationTests {
    var base: URL? { ProcessInfo.processInfo.environment["TROVE_RELAY_URL"].flatMap(URL.init(string:)) }

    @Test func pairingSyncBlobsAndInbox() async throws {
        guard let base else { return }
        let keys = VaultKeys.generate()

        // Mac creates the vault; iPhone joins with the QR payload.
        let mac = try await RelayClient.createVault(baseURL: base, publicKey: keys.publicKeyBase64URL, deviceName: "Mac", deviceKind: "mac")
        let macClient = RelayClient(baseURL: base, vaultId: mac.vaultId, token: mac.deviceToken)
        let pairing = try await macClient.createPairing()
        let qr = PairingPayload(vaultId: mac.vaultId, keys: keys.exported(), encrypted: true, relayURL: base.absoluteString, pairingCode: pairing.pairingCode)
        let scanned = try #require(PairingPayload(scanned: qr.url.absoluteString))
        let phoneKeys = try VaultKeys(scanned.keys)
        let phone = try await RelayClient.join(baseURL: base, vaultId: scanned.vaultId, pairingCode: try #require(scanned.pairingCode), deviceName: "iPhone", deviceKind: "ios")
        let phoneClient = RelayClient(baseURL: base, vaultId: phone.vaultId, token: phone.deviceToken)
        #expect(try await macClient.devices().count == 2)

        // Journals sync through the relay.
        let macLib = Library(engine: SyncEngine(device: mac.deviceId, keys: keys, transports: [RelayTransport(client: macClient)]))
        let phoneLib = Library(engine: SyncEngine(device: phone.deviceId, keys: phoneKeys, transports: [RelayTransport(client: phoneClient)]))
        let noteId = await macLib.addNote(title: "Hello", body: "from the Mac")
        let fileId = try await macLib.addFile(Data("photo bytes".utf8), name: "p.jpg", mime: "image/jpeg")
        #expect(await macLib.sync().errors.isEmpty)
        #expect(await phoneLib.sync().pulled >= 1)
        #expect(await phoneLib.item(noteId)?.body == "from the Mac")
        let file = try #require(await phoneLib.item(fileId))
        #expect(try await phoneLib.attachmentData(file.attachments[0]) == Data("photo bytes".utf8))

        // A browser extension seals into the inbox with only the public key + inbox token.
        let ext = RelayClient(baseURL: base, vaultId: mac.vaultId, token: try #require(mac.inboxToken))
        let env = InboxEnvelope(header: .init(source: "web", mime: "text/plain", url: "https://example.com/story", title: "Story"), body: Data("great quote".utf8))
        _ = try await ext.postInbox(sealed: try TRV1.seal(env.encoded(), to: keys.publicKey), source: "web")
        let imported = await InboxSync.run(client: phoneClient, keys: phoneKeys, library: phoneLib)
        #expect(imported.errors.isEmpty && imported.imported.count == 1)
        #expect(try await phoneClient.inbox().isEmpty)
        _ = await macLib.sync()
        #expect(await macLib.search("great quote").count == 1)

        // Price watches follow the item field; publishing gives a public page.
        let (product, _) = await phoneLib.addLink(URL(string: "https://shop.example/lamp")!, title: "Lamp")
        await phoneLib.setWatching(product, url: URL(string: "https://shop.example/lamp")!)
        var watched = await PriceWatchSync.run(client: macClient, library: phoneLib)
        #expect(watched.added == 1 && watched.errors.isEmpty)
        #expect(try await macClient.watches().map(\.id) == [product])
        await phoneLib.setWatching(product, url: nil)
        watched = await PriceWatchSync.run(client: macClient, library: phoneLib)
        #expect(watched.removed == 1)
        #expect(try await macClient.watches().isEmpty)

        let slug = RelayClient.newSlug()
        let page = try await macClient.publish(slug: slug, title: "Hello", markdown: "from **Trove**")
        #expect(page.absoluteString == base.absoluteString.trimmingCharacters(in: ["/"]) + "/p/\(mac.vaultId)/\(slug)")
        let (html, _) = try await URLSession.shared.data(from: page)
        #expect(String(decoding: html, as: UTF8.self).contains("<strong>Trove</strong>"))
        #expect(try await macClient.publishedPages().map(\.slug) == [slug])
        try await macClient.unpublish(slug: slug)
        #expect(try await macClient.publishedPages().isEmpty)

        // Revoked devices lose access.
        try await macClient.revoke(device: phone.deviceId)
        await #expect(throws: TransportError.self) { try await phoneClient.devices() }
    }
}
