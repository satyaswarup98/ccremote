import Foundation
import Security

// Pairing tokens grant control of Claude on a Mac, so they live in the Keychain, not UserDefaults.
// One entry holds every paired Mac plus which one is active.
enum PairingStore {
    struct Saved: Codable {
        var active: String?          // Pairing.id
        var items: [Pairing]
    }

    private static let service = "com.satya.ccremote.pairings"
    private static let legacyService = "com.satya.ccremote.pairing"   // single-Mac builds

    static func load() -> Saved {
        if let data = read(service), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            return saved
        }
        // Carry over the pairing from the single-Mac version, so nobody has to pair again.
        if let data = read(legacyService), let old = try? JSONDecoder().decode(Pairing.self, from: data) {
            let saved = Saved(active: old.id, items: [old])
            save(saved)
            delete(legacyService)
            return saved
        }
        return Saved(active: nil, items: [])
    }

    static func save(_ saved: Saved) {
        delete(service)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ] as CFDictionary, nil)
    }

    private static func read(_ service: String) -> Data? {
        var out: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(_ service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
