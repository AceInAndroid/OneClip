import Foundation
import CryptoKit
import CommonCrypto
import Security

enum PasteLightCrypto {
    static let minimumPBKDF2Iterations: UInt32 = 600_000
    static let derivedKeyBytes = 32
    static let saltBytes = 16
    static let chunkSize = 1024 * 1024
    private static let blobMagic = Data("PLBLOB01".utf8)

    struct ChunkedPayloadHeader: Codable {
        let formatVersion: Int
        let objectID: String
        let plaintextByteCount: Int64
        let plaintextDigest: String
        let chunkSize: Int
    }

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }

    static func calibratedIterations(passphrase: String, salt: Data) -> UInt32 {
        let passwordLength = passphrase.precomposedStringWithCompatibilityMapping.utf8.count
        let calibrated = CCCalibratePBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordLength,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            derivedKeyBytes,
            250
        )
        return max(minimumPBKDF2Iterations, calibrated)
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let normalized = passphrase.precomposedStringWithCompatibilityMapping
        let passwordBytes = Array(normalized.utf8)
        let saltBytes = Array(salt)
        var output = [UInt8](repeating: 0, count: derivedKeyBytes)

        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            saltBytes.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress,
                    passwordBuffer.count,
                    saltBuffer.baseAddress,
                    saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &output,
                    output.count
                )
            }
        }

        guard status == kCCSuccess else { throw WebDAVFeatureError.encryptionFailed }
        return SymmetricKey(data: Data(output))
    }

    static func encrypt(_ plaintext: Data, using key: SymmetricKey, aad: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
            guard let combined = sealedBox.combined else { throw WebDAVFeatureError.encryptionFailed }
            let envelope = EncryptedEnvelope(
                formatVersion: EncryptedEnvelope.formatVersion,
                combined: combined
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch let error as WebDAVFeatureError {
            throw error
        } catch {
            throw WebDAVFeatureError.encryptionFailed
        }
    }

    static func decrypt(_ encryptedData: Data, using key: SymmetricKey, aad: Data) throws -> Data {
        do {
            let envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: encryptedData)
            guard envelope.formatVersion == EncryptedEnvelope.formatVersion else {
                throw WebDAVFeatureError.decryptionFailed
            }
            let box = try AES.GCM.SealedBox(combined: envelope.combined)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch let error as WebDAVFeatureError {
            throw error
        } catch {
            throw WebDAVFeatureError.decryptionFailed
        }
    }

    static func remoteObjectID(fingerprint: String, kind: SyncPayloadKind, key: SymmetricKey) -> String {
        let material = Data("\(kind.rawValue)|\(fingerprint)".utf8)
        let code = HMAC<SHA256>.authenticationCode(for: material, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func keyCheck(for key: SymmetricKey, accountID: UUID) -> Data {
        let material = Data("PasteLight|account-key-check|1|\(accountID.uuidString)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: material, using: key))
    }

    static func keyCheckIsValid(_ keyCheck: Data, key: SymmetricKey, accountID: UUID) -> Bool {
        let expected = self.keyCheck(for: key, accountID: accountID)
        guard expected.count == keyCheck.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(expected, keyCheck) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(fileAt url: URL) throws -> (digest: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            byteCount += Int64(chunk.count)
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, byteCount)
    }

    @discardableResult
    static func encryptFile(
        sourceURL: URL,
        destinationURL: URL,
        objectID: String,
        accountID: UUID,
        key: SymmetricKey
    ) throws -> ChunkedPayloadHeader {
        let sourceInfo = try sha256Hex(fileAt: sourceURL)
        let header = ChunkedPayloadHeader(
            formatVersion: 1,
            objectID: objectID,
            plaintextByteCount: sourceInfo.byteCount,
            plaintextDigest: sourceInfo.digest,
            chunkSize: chunkSize
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(header)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw WebDAVFeatureError.encryptionFailed
        }
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }

        try output.write(contentsOf: blobMagic)
        try output.write(contentsOf: uint32Data(UInt32(headerData.count)))
        try output.write(contentsOf: headerData)

        var chunkIndex: UInt64 = 0
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            let aad = chunkAAD(
                accountID: accountID,
                objectID: objectID,
                chunkIndex: chunkIndex,
                plaintextByteCount: sourceInfo.byteCount
            )
            let sealed = try AES.GCM.seal(chunk, using: key, authenticating: aad)
            guard let combined = sealed.combined,
                  combined.count <= chunkSize + 64 else {
                throw WebDAVFeatureError.encryptionFailed
            }
            try output.write(contentsOf: uint32Data(UInt32(combined.count)))
            try output.write(contentsOf: combined)
            chunkIndex &+= 1
        }
        try output.synchronize()
        return header
    }

    @discardableResult
    static func decryptFile(
        sourceURL: URL,
        destinationURL: URL,
        expectedObjectID: String,
        accountID: UUID,
        key: SymmetricKey
    ) throws -> ChunkedPayloadHeader {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        guard try input.read(upToCount: blobMagic.count) == blobMagic,
              let headerLengthData = try input.read(upToCount: 4),
              headerLengthData.count == 4 else {
            throw WebDAVFeatureError.corruptedPayload
        }
        let headerLength = Int(readUInt32(headerLengthData))
        guard headerLength > 0, headerLength <= 64 * 1024,
              let headerData = try input.read(upToCount: headerLength),
              headerData.count == headerLength else {
            throw WebDAVFeatureError.corruptedPayload
        }

        let header = try JSONDecoder().decode(ChunkedPayloadHeader.self, from: headerData)
        guard header.formatVersion == 1,
              header.objectID == expectedObjectID,
              header.chunkSize == chunkSize,
              header.plaintextByteCount >= 0 else {
            throw WebDAVFeatureError.corruptedPayload
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw WebDAVFeatureError.decryptionFailed
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        var chunkIndex: UInt64 = 0

        while true {
            guard let lengthData = try input.read(upToCount: 4) else { break }
            if lengthData.isEmpty { break }
            guard lengthData.count == 4 else { throw WebDAVFeatureError.corruptedPayload }

            let encryptedLength = Int(readUInt32(lengthData))
            guard encryptedLength > 28, encryptedLength <= chunkSize + 64,
                  let encryptedChunk = try input.read(upToCount: encryptedLength),
                  encryptedChunk.count == encryptedLength else {
                throw WebDAVFeatureError.corruptedPayload
            }

            let aad = chunkAAD(
                accountID: accountID,
                objectID: expectedObjectID,
                chunkIndex: chunkIndex,
                plaintextByteCount: header.plaintextByteCount
            )
            let box = try AES.GCM.SealedBox(combined: encryptedChunk)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
            totalBytes += Int64(plaintext.count)
            guard totalBytes <= header.plaintextByteCount else {
                throw WebDAVFeatureError.corruptedPayload
            }
            hasher.update(data: plaintext)
            try output.write(contentsOf: plaintext)
            chunkIndex &+= 1
        }
        try output.synchronize()

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard totalBytes == header.plaintextByteCount,
              digest == header.plaintextDigest else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw WebDAVFeatureError.corruptedPayload
        }
        return header
    }

    static func rawData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func chunkAAD(
        accountID: UUID,
        objectID: String,
        chunkIndex: UInt64,
        plaintextByteCount: Int64
    ) -> Data {
        Data("PasteLight|blob|1|\(accountID.uuidString)|\(objectID)|\(chunkIndex)|\(plaintextByteCount)".utf8)
    }

    private static func uint32Data(_ value: UInt32) -> Data {
        var bigEndianValue = value.bigEndian
        return Data(bytes: &bigEndianValue, count: MemoryLayout<UInt32>.size)
    }

    private static func readUInt32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: UInt32.self).bigEndian
        }
    }
}

struct WebDAVCredential: Equatable {
    let username: String
    let password: String
}

protocol WebDAVSecretStoring: AnyObject {
    func saveCredential(_ credential: WebDAVCredential, for configuration: WebDAVConfiguration) throws
    func credential(for configuration: WebDAVConfiguration) -> WebDAVCredential?
    func deleteCredential(for configuration: WebDAVConfiguration)
    func saveMasterKey(_ key: SymmetricKey, accountID: UUID) throws
    func masterKey(accountID: UUID) -> SymmetricKey?
    func deleteMasterKey(accountID: UUID)
}

final class WebDAVSecretStore: WebDAVSecretStoring {
    static let shared = WebDAVSecretStore()
    private let masterKeyService = "com.oneclip.app.webdav.master-key"

    private init() {}

    func saveCredential(_ credential: WebDAVCredential, for configuration: WebDAVConfiguration) throws {
        guard let url = configuration.baseURL, let host = url.host else {
            throw WebDAVFeatureError.invalidURL
        }
        let query = internetPasswordQuery(host: host, url: url, username: credential.username)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = Data(credential.password.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WebDAVFeatureError.serverMessage("无法保存 WebDAV 密码（Keychain \(status)）")
        }
    }

    func credential(for configuration: WebDAVConfiguration) -> WebDAVCredential? {
        guard let url = configuration.baseURL, let host = url.host else { return nil }
        var query = internetPasswordQuery(host: host, url: url, username: configuration.username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return WebDAVCredential(username: configuration.username, password: password)
    }

    func deleteCredential(for configuration: WebDAVConfiguration) {
        guard let url = configuration.baseURL, let host = url.host else { return }
        SecItemDelete(internetPasswordQuery(host: host, url: url, username: configuration.username) as CFDictionary)
    }

    func saveMasterKey(_ key: SymmetricKey, accountID: UUID) throws {
        let account = accountID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: masterKeyService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = PasteLightCrypto.rawData(key)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WebDAVFeatureError.serverMessage("无法保存同步密钥（Keychain \(status)）")
        }
    }

    func masterKey(accountID: UUID) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: masterKeyService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count == PasteLightCrypto.derivedKeyBytes else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    func deleteMasterKey(accountID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: masterKeyService,
            kSecAttrAccount as String: accountID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func internetPasswordQuery(host: String, url: URL, username: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrPath as String: url.path.isEmpty ? "/" : url.path
        ]
        if let port = url.port {
            query[kSecAttrPort as String] = port
        }
        return query
    }
}
