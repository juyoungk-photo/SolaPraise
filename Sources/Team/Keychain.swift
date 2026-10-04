//
//  Keychain.swift
//  SolaPraise
//
//  The planning account's refresh token.
//
//  UserDefaults is a plist in the app container, readable from a backup. A
//  refresh token is a long-lived credential to somebody's Google account, so
//  it goes here instead — and with ThisDeviceOnly, so restoring a backup onto
//  another device does not carry it along.
//

import Foundation
import Security

enum Keychain {
    private static let service = "com.juyoungkim.solapraise"

    static func write(_ account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(account)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}
