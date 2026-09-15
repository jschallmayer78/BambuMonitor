//
//  KeychainHelper.swift
//  BambuMonitor
//
//  Speichert Zugangscodes der Drucker sicher im Keychain – ein Eintrag
//  pro Drucker-Konfiguration (Account = printerAccessCode-<UUID>).
//

import Foundation
import Security

enum KeychainHelper {
    private static let service = "BambuMonitor"
    private static let legacyAccount = "printerAccessCode"

    static func loadAccessCode(for printerID: UUID) -> String? {
        load(account: account(for: printerID))
    }

    static func saveAccessCode(_ code: String, for printerID: UUID) {
        save(code, account: account(for: printerID))
    }

    static func deleteAccessCode(for printerID: UUID) {
        save("", account: account(for: printerID))
    }

    /// Access Code aus Versionen vor der Multi-Drucker-Unterstützung.
    static func legacyAccessCode() -> String? {
        load(account: legacyAccount)
    }

    static func deleteLegacyAccessCode() {
        save("", account: legacyAccount)
    }

    // MARK: - Intern

    private static func account(for printerID: UUID) -> String {
        "printerAccessCode-\(printerID.uuidString)"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, account: String) {
        let query = baseQuery(account: account)
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
