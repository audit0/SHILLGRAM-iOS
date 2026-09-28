/*
 * SHILLGRAM: SHILLVPN built into the app.
 *
 * The subscription link, the fetched body, the site cabinet key, the device
 * id and the user's own previous proxy live in the iOS Keychain (the app's
 * default access group: a sideloaded build has no app group), readable only
 * on this device after the first unlock. Never logged.
 */
import Foundation
import Security

public final class SecretStore {
    private let service: String

    public init(service: String = "io.github.audit0.shillgram.vpn") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: key
        ]
    }

    public func read(_ key: String) -> Data? {
        var query = self.query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    public func readString(_ key: String) -> String? {
        return self.read(key).map { String(decoding: $0, as: UTF8.self) }
    }

    @discardableResult
    public func write(_ key: String, _ data: Data) -> Bool {
        let query = self.query(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (key, value) in attributes {
                add[key] = value
            }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    public func write(_ key: String, _ string: String) -> Bool {
        return self.write(key, Data(string.utf8))
    }

    public func remove(_ key: String) {
        SecItemDelete(self.query(key) as CFDictionary)
    }
}
