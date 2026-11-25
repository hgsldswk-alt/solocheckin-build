import Foundation
import Security

enum TrialClock {
    static func firstPaidLaunch(at date: Date) async -> Date {
        await Task.detached(priority: .utility) {
            let key: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.hgsldswk.solocheckin.trial-clock",
                kSecAttrAccount as String: "first-paid-launch"
            ]
            if let saved = read(key) { return min(saved, date) }
            var attributes = key
            attributes[kSecValueData as String] = Data(String(date.timeIntervalSince1970).utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem, let saved = read(key) { return min(saved, date) }
            return date
        }.value
    }

    private static func read(_ key: [String: Any]) -> Date? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8),
              let epoch = TimeInterval(value), epoch.isFinite else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
