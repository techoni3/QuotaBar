// Generates the Sparkle (EdDSA/ed25519) update-key pair.
//
//   swift scripts/generate-sparkle-keys.swift
//
// Output:
//  - $HOME/aimeter-sparkle-ed25519.private  — "ed25519 <base64(32-byte seed)>",
//    chmod 600. NEVER commit this file; it lives outside the repo.
//  - Support/SparklePublicKey.txt          — base64 of the 32-byte public key
//    (committed; this is SUPublicEDKey for Info.plist and the appcast).
//
// Uses CryptoKit's standard ed25519 (RFC 8032) — Sparkle 2 verifies appcast
// signatures with the same algorithm, so `sparkle-sign.swift` (below) produces
// compatible signatures without shipping Sparkle's own key tools.
import CryptoKit
import Foundation

let seed = Curve25519.Signing.PrivateKey()
let publicB64 = seed.publicKey.rawRepresentation.base64EncodedString()

let home = FileManager.default.homeDirectoryForCurrentUser
let privateURL = home.appendingPathComponent("aimeter-sparkle-ed25519.private")
let privateLine = "ed25519 " + seed.rawRepresentation.base64EncodedString() + "\n"
try Data(privateLine.utf8).write(to: privateURL)
try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)

let supportDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Support")
try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
try Data((publicB64 + "\n").utf8).write(to: supportDir.appendingPathComponent("SparklePublicKey.txt"))

print("private key : \(privateURL.path) (NOT committed, mode 600)")
print("public key  : \(supportDir.appendingPathComponent("SparklePublicKey.txt").path)")
print("SUPublicEDKey = \(publicB64)")

// Self-check: the private seed round-trips and signs verifiably.
let roundTrip = try Curve25519.Signing.PrivateKey(rawRepresentation: seed.rawRepresentation)
let signature = try roundTrip.signature(for: Data("aimeter-selftest".utf8))
print("selftest     : \(roundTrip.publicKey.rawRepresentation == seed.publicKey.rawRepresentation) (signature size \(signature.count)/64)")