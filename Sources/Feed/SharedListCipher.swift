//
//  SharedListCipher.swift
//  SolaPraise
//
//  The church's 관심 채널 list, sealed with a password its members share.
//
//  WHY: the list lives in a Drive folder shared by link, so anyone who has
//  the link can read it — and what it lists are the church's 일부 공개
//  services, unlisted precisely so that they are not open to everyone. The
//  manager's app now writes the list as one sealed cell; a member's app
//  opens it with the church's password, entered once and kept in the
//  Keychain. Someone with only the folder link sees a block of letters.
//
//  WHAT IT DOES NOT DO: a member who has the password can still share a
//  video's link, and YouTube itself treats an unlisted video as open to
//  anyone who has its link. This keeps the catalogue out of a public
//  folder; it is not access control on YouTube.
//
//  The format, in one cell: 「SPENC1:」 + base64(salt ‖ AES-GCM box), the key
//  derived from the password with PBKDF2-HMAC-SHA256 — slow on purpose, so
//  a guessed password costs something to try. Foundation, CryptoKit and
//  CommonCrypto only, so Tools/check-shared-list-cipher.swift runs it.
//

import Foundation
import CryptoKit
import CommonCrypto
import Security

enum SharedListCipher {

    static let prefix = "SPENC1:"
    static let rounds: UInt32 = 200_000

    /// The text, sealed. Nil only if the system's random source fails.
    static func seal(_ text: String, password: String) -> String? {
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard ok == errSecSuccess, let key = key(password, salt: salt),
              let box = try? AES.GCM.seal(Data(text.utf8), using: key).combined else { return nil }
        return prefix + (salt + box).base64EncodedString()
    }

    /// The text, or nil for a wrong password or a damaged cell.
    static func open(_ sealed: String, password: String) -> String? {
        guard sealed.hasPrefix(prefix),
              let raw = Data(base64Encoded: String(sealed.dropFirst(prefix.count))), raw.count > 16 + 28,
              let key = key(password, salt: raw.prefix(16)),
              let box = try? AES.GCM.SealedBox(combined: raw.dropFirst(16)),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Sealed cells in a sheet's text, and the text without them — the
    /// rest is read for plain links as before. Base64 can spell 「/live/」,
    /// so a sealed cell must never be read as links.
    static func split(_ text: String) -> (sealed: [String], rest: String) {
        guard let regex = try? NSRegularExpression(pattern: #"SPENC1:[A-Za-z0-9+/=]+"#) else { return ([], text) }
        let range = NSRange(text.startIndex..., in: text)
        let sealed = regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        return (sealed, regex.stringByReplacingMatches(in: text, range: range, withTemplate: " "))
    }

    private static func key(_ password: String, salt: Data) -> SymmetricKey? {
        let secret = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 secret.map { Int8(bitPattern: $0) }, secret.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                 &derived, derived.count)
        }
        return status == kCCSuccess ? SymmetricKey(data: derived) : nil
    }
}
