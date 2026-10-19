// Verifies a Swift-sealed vector (see CryptoTests.exportsSwiftVectorWhenAsked) opens with the Worker code.
// Run: node --experimental-strip-types scripts/check-swift-vector.ts <vector.json>
import { readFileSync } from "node:fs";
import { b64uDecode, open } from "../src/crypto.ts";

const fixture = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/trv1.json", import.meta.url), "utf8"));
const vector = JSON.parse(readFileSync(process.argv[2]!, "utf8"));
const pub = b64uDecode(fixture.vaultPublicKey);
const priv = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "X25519", d: fixture.vaultPrivateKey, x: fixture.vaultPublicKey }, { name: "X25519" }, false, ["deriveBits"]);
const plain = await open(b64uDecode(vector.box), { recipientPrivateKey: priv, recipientPublicKey: pub });
const expected = b64uDecode(vector.plaintext);
if (plain.length !== expected.length || plain.some((b, i) => b !== expected[i])) throw new Error("MISMATCH");
console.log("OK: Worker opened Swift-sealed box:", new TextDecoder().decode(plain));
