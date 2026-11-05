import Foundation
import Testing
@testable import TroveCore

/// The relay's code to create a vault (PROTOCOL.md §4, learn-pivot plan §7 E2): the apps ask for it only when
/// the relay's answer says so.
@Suite struct VaultCodeTests {
    @Test func theRelaysAnswerSaysWhenACodeIsNeeded() {
        #expect(RelayClient.createCodeProblem(TransportError.http(403, #"{"error":"x","code":"create_code_required"}"#)) == .needed)
        #expect(RelayClient.createCodeProblem(TransportError.http(429, #"{"error":"x","code":"create_code_limited"}"#)) == .limited)
        // Closed completely (ALLOW_NEW_VAULTS false), or anything else: not about the code.
        #expect(RelayClient.createCodeProblem(TransportError.http(403, #"{"error":"this relay isn't accepting new vaults"}"#)) == nil)
        #expect(RelayClient.createCodeProblem(TransportError.notFound) == nil)
    }
}
