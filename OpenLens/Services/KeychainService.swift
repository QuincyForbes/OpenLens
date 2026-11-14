import CryptoKit
import Foundation
import Security
import os

/// Keychain wrapper for storing sensitive data.
/// Supports both simple String values and Codable objects (encoded as JSON Data).
enum KeychainService {

    private static let serviceName = Bundle.main.bundleIdentifier ?? "com.openlens"
    private static let logger = Logger(subsystem: serviceName, category: "Keychain")
    #if targetEnvironment(macCatalyst)
    private static let macFallbackStore = EncryptedFileCredentialStore.defaultStore(serviceName: serviceName)
    #endif

    // MARK: - String API (backward-compatible)

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return saveData(key: key, data: data)
    }

    static func load(key: String) -> String? {
        guard let data = loadData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query = baseQuery(key: key)
        let status = SecItemDelete(query as CFDictionary)
        #if targetEnvironment(macCatalyst)
        macFallbackStore?.delete(key: key)
        if status != errSecSuccess && status != errSecItemNotFound && status != errSecMissingEntitlement {
            logger.warning("Keychain delete failed for '\(key, privacy: .public)': \(status)")
        }
        #else
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("Keychain delete failed for '\(key, privacy: .public)': \(status)")
        }
        #endif
    }

    // MARK: - Codable API

    @discardableResult
    static func saveCodable<T: Encodable>(_ value: T, key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            return saveData(key: key, data: data)
        } catch {
            logger.error("Keychain encode failed for '\(key, privacy: .public)': \(error, privacy: .public)")
            return false
        }
    }

    static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = loadData(key: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("Keychain decode failed for '\(key, privacy: .public)': \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Raw Data API

    @discardableResult
    static func saveData(key: String, data: Data) -> Bool {
        let query = baseQuery(key: key)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            #if targetEnvironment(macCatalyst)
            macFallbackStore?.delete(key: key)
            #endif
            return true
        }
        // Never wipe an existing item when Keychain is temporarily locked (`errSecInteractionNotAllowed`).
        if updateStatus == errSecInteractionNotAllowed {
            logger.error("Keychain update deferred while device locked for '\(key, privacy: .public)'")
            return false
        }
        if updateStatus != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            #if targetEnvironment(macCatalyst)
            macFallbackStore?.delete(key: key)
            #endif
            return true
        }

        #if targetEnvironment(macCatalyst)
        // Ad-hoc signed Mac Catalyst builds do not carry Data Protection Keychain entitlements
        // (`errSecMissingEntitlement = -34018`). Fall back to an owner-only AES-GCM store in
        // Application Support so saved server passwords survive app restarts and Mac reboots.
        if let macFallbackStore, macFallbackStore.save(key: key, data: data) {
            return true
        }
        #endif

        logger.error("Keychain save failed for '\(key, privacy: .public)': \(status)")
        return false
    }

    static func loadData(key: String) -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return data
        }
        #if targetEnvironment(macCatalyst)
        return macFallbackStore?.load(key: key)
        #else
        return nil
        #endif
    }

    // MARK: - Helpers

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
        ]
    }
}

/// Encrypted file-backed credential fallback used on ad-hoc signed Mac Catalyst builds where
/// the Data Protection Keychain rejects `SecItem*` with `errSecMissingEntitlement` (`-34018`).
nonisolated final class EncryptedFileCredentialStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private static let masterKeyFileName = ".master.key"

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultStore(serviceName: String) -> EncryptedFileCredentialStore? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let sanitizedService = serviceName.replacingOccurrences(of: "/", with: "_")
        let directory = appSupport
            .appendingPathComponent(sanitizedService, isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
        return EncryptedFileCredentialStore(directory: directory)
    }

    @discardableResult
    func save(key: String, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureDirectory()
            let masterKey = try loadOrCreateMasterKey()
            let sealed = try AES.GCM.seal(
                data,
                using: masterKey,
                authenticating: Data(key.utf8)
            )
            guard let combined = sealed.combined else { return false }
            let targetURL = entryURL(for: key)
            try writeProtectedFile(combined, to: targetURL)
            return true
        } catch {
            return false
        }
    }

    func load(key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let targetURL = entryURL(for: key)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return nil
        }
        do {
            let masterKey = try loadExistingMasterKey()
            let combined = try Data(contentsOf: targetURL)
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                box,
                using: masterKey,
                authenticating: Data(key.utf8)
            )
        } catch {
            return nil
        }
    }

    func delete(key: String) {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: entryURL(for: key))
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } else {
            try? fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private func loadOrCreateMasterKey() throws -> SymmetricKey {
        if let existing = try? loadExistingMasterKey() {
            return existing
        }
        let generated = SymmetricKey(size: .bits256)
        let rawBytes = generated.withUnsafeBytes { Data($0) }
        try writeProtectedFile(rawBytes, to: directory.appendingPathComponent(Self.masterKeyFileName))
        return generated
    }

    private func loadExistingMasterKey() throws -> SymmetricKey {
        let keyURL = directory.appendingPathComponent(Self.masterKeyFileName)
        let rawBytes = try Data(contentsOf: keyURL)
        guard rawBytes.count == 32 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return SymmetricKey(data: rawBytes)
    }

    private func writeProtectedFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func entryURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).bin")
    }
}
