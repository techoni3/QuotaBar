// Signs a file with the local Sparkle EdDSA private key and prints the base64
// ed25519 signature for the appcast <sparkle:edSignature>.
//
//   swift scripts/sparkle-sign.swift dist/AIMeter-0.1.0.dmg
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: swift scripts/sparkle-sign.swift <file>")
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))

let home = FileManager.default.homeDirectoryForCurrentUser
let keyText = try String(contentsOf: home.appendingPathComponent("aimeter-sparkle-ed25519.private"),
                         encoding: .utf8)
let b64 = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: "ed25519 ", with: "")
guard let seed = Data(base64Encoded: b64) else { fatalError("bad private key seed") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let signature = try key.signature(for: data)
print(signature.base64EncodedString())