#!/usr/bin/env swift
import CryptoKit
import Foundation

// Uses only the public key shipped in the app, never the private signing key.
// Usage: swift scripts/verify-update.swift archive.zip signature-base64 public-key.txt
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 4 else {
    fail("Usage: verify-update.swift archive.zip signature-base64 public-key.txt")
}
do {
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let keyText = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
        fail("Invalid Ed25519 public key or signature")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: archive) else {
        fail("REJECTED: archive signature is invalid")
    }
    print("Verified archive Ed25519 signature against the configured public key")
} catch {
    fail("Verification failed: \(error.localizedDescription)")
}
