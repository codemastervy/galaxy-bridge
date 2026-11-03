import Foundation
import Security

/// Where pairing secrets live: the Keychain, this device only, never synced or backed up.
public protocol SecretStore {
    func save(_ data: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "nz.galaxybridge.wearlink") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Use the data-protection keychain on macOS too, so the accessibility class applies.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func save(_ data: Data, account: String) throws {
        try delete(account: account)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func load(account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return out as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// What a completed pairing needs to remember. Non-secret identity goes alongside the secret
/// session so a resume can find the right watch; the whole record is stored as one Keychain item.
public struct PairingRecord: Codable, Equatable {
    /// CoreBluetooth identifier of the watch (per-host, not the hardware address).
    public var watchIdentifier: UUID
    public var watchNodeId: String?
    public var pairedAt: Date
    /// Opaque resumable session from the encryption layer. Never logged.
    public var session: Data?

    public init(watchIdentifier: UUID, watchNodeId: String? = nil, pairedAt: Date = Date(), session: Data? = nil) {
        self.watchIdentifier = watchIdentifier
        self.watchNodeId = watchNodeId
        self.pairedAt = pairedAt
        self.session = session
    }
}

public struct PairingRecords {
    private let store: SecretStore
    private static let account = "pairing-record"

    public init(store: SecretStore = KeychainStore()) {
        self.store = store
    }

    public func save(_ record: PairingRecord) throws {
        try store.save(JSONEncoder().encode(record), account: Self.account)
    }

    public func load() throws -> PairingRecord? {
        try store.load(account: Self.account).map { try JSONDecoder().decode(PairingRecord.self, from: $0) }
    }

    public func forget() throws {
        try store.delete(account: Self.account)
    }
}
