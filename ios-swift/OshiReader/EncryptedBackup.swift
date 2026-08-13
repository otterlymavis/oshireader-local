import CommonCrypto
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

enum EncryptedBackupError: LocalizedError, Equatable {
    case invalidPassword
    case invalidEnvelope
    case unsupportedVersion
    case authenticationFailed
    case keyDerivationFailed
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Password must be between 12 and 256 characters."
        case .invalidEnvelope:
            return "This is not a valid OshiReader encrypted backup."
        case .unsupportedVersion:
            return "This encrypted backup version is not supported."
        case .authenticationFailed:
            return "The password is incorrect or the backup was corrupted."
        case .keyDerivationFailed:
            return "The encrypted backup key could not be derived."
        case .payloadTooLarge:
            return "The encrypted backup file is too large."
        }
    }
}

enum EncryptedBackupCodec {
    static let magic = Data("OSHIREADER".utf8)
    static let currentVersion: UInt8 = 2
    static let saltLength = 16
    static let keyLength = 32
    /// Iteration count used for every v1 envelope ever produced by this app.
    /// Not stored on-disk for v1 (it predates the iteration-count header
    /// field), so it must stay fixed to keep old backups decryptable.
    static let legacyIterations = 150_000
    /// Iteration count for v2+ envelopes, which carry their own iteration
    /// count in the header so this can be raised again in the future
    /// without breaking existing backups.
    static let iterations = 600_000
    /// Upper bound on a v2 envelope's header-supplied iteration count — a
    /// generous ceiling above `iterations` for future increases, without
    /// letting an untrusted file force an effectively unbounded PBKDF2 run.
    static let maximumIterations = 5_000_000
    static let maximumPasswordLength = 256
    static let maximumEnvelopeBytes = LocalDB.maximumBackupBytes + 512

    /// magic + version + saltLength + nonceLength + tagLength
    private static let baseHeaderLength = magic.count + 4
    /// v2 header additionally carries a 4-byte big-endian iteration count.
    private static let v2HeaderLength = baseHeaderLength + 4

    static func validatePassword(_ password: String) throws {
        guard password.count >= 12, password.count <= maximumPasswordLength else {
            throw EncryptedBackupError.invalidPassword
        }
    }

    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        try validatePassword(password)
        guard plaintext.count <= LocalDB.maximumBackupBytes else {
            throw EncryptedBackupError.payloadTooLarge
        }

        let salt = try randomData(count: saltLength)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let nonce = AES.GCM.Nonce()
        let header = makeHeader(saltLength: salt.count, nonceLength: 12, tagLength: 16, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)

        var envelope = header
        envelope.append(salt)
        envelope.append(contentsOf: sealed.nonce)
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        guard envelope.count <= maximumEnvelopeBytes else {
            throw EncryptedBackupError.payloadTooLarge
        }
        return envelope
    }

    static func decrypt(_ envelope: Data, password: String) throws -> Data {
        try validatePassword(password)
        guard envelope.count >= baseHeaderLength else { throw EncryptedBackupError.invalidEnvelope }
        guard Data(envelope.prefix(magic.count)) == magic else { throw EncryptedBackupError.invalidEnvelope }

        let version = envelope[magic.count]
        guard version == 1 || version == 2 else { throw EncryptedBackupError.unsupportedVersion }

        let saltLength = Int(envelope[magic.count + 1])
        let nonceLength = Int(envelope[magic.count + 2])
        let tagLength = Int(envelope[magic.count + 3])
        guard saltLength == Self.saltLength,
              nonceLength == 12,
              tagLength == 16 else {
            throw EncryptedBackupError.invalidEnvelope
        }

        let headerLength: Int
        let iterationsUsed: Int
        if version == 1 {
            headerLength = baseHeaderLength
            iterationsUsed = legacyIterations
        } else {
            guard envelope.count >= v2HeaderLength else { throw EncryptedBackupError.invalidEnvelope }
            iterationsUsed = uint32(fromBigEndianBytes: Data(envelope[baseHeaderLength..<v2HeaderLength]))
            // Bound the untrusted header value — without a ceiling, a
            // corrupt or malicious file could set this near UInt32.max and
            // hang PBKDF2 for an effectively unbounded time.
            guard iterationsUsed > 0, iterationsUsed <= maximumIterations else {
                throw EncryptedBackupError.invalidEnvelope
            }
            headerLength = v2HeaderLength
        }
        guard envelope.count <= maximumEnvelopeBytes else { throw EncryptedBackupError.invalidEnvelope }

        let payloadStart = headerLength
        let saltEnd = payloadStart + saltLength
        let nonceEnd = saltEnd + nonceLength
        let tagStart = envelope.count - tagLength
        guard saltEnd <= nonceEnd, nonceEnd < tagStart, tagStart < envelope.count else {
            throw EncryptedBackupError.invalidEnvelope
        }

        let salt = Data(envelope[payloadStart..<saltEnd])
        let nonceData = Data(envelope[saltEnd..<nonceEnd])
        let ciphertext = Data(envelope[nonceEnd..<tagStart])
        let tag = Data(envelope[tagStart..<envelope.count])
        let key = try deriveKey(password: password, salt: salt, iterations: iterationsUsed)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealed, using: key, authenticating: envelope.prefix(headerLength))
        } catch CryptoKitError.authenticationFailure {
            throw EncryptedBackupError.authenticationFailed
        } catch {
            throw EncryptedBackupError.invalidEnvelope
        }
    }

    private static func makeHeader(saltLength: Int, nonceLength: Int, tagLength: Int, iterations: Int) -> Data {
        var header = magic
        header.append(currentVersion)
        header.append(UInt8(saltLength))
        header.append(UInt8(nonceLength))
        header.append(UInt8(tagLength))
        header.append(uint32BigEndianBytes(iterations))
        return header
    }

    private static func uint32BigEndianBytes(_ value: Int) -> Data {
        // Shift the raw value directly — `.bigEndian` returns a value whose
        // in-*memory* layout is big-endian, not one whose numeric value is
        // byte-order-reversed, so shifting on top of `.bigEndian` (rather
        // than reading its memory via `withUnsafeBytes`) double-converts.
        let v = UInt32(value)
        return Data([
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ])
    }

    private static func uint32(fromBigEndianBytes data: Data) -> Int {
        let bytes = [UInt8](data)
        guard bytes.count == 4 else { return 0 }
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Int(value)
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw EncryptedBackupError.keyDerivationFailed }
        return Data(bytes)
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw EncryptedBackupError.keyDerivationFailed
        }
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBuffer in
            passwordData.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBuffer.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw EncryptedBackupError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}

extension UTType {
    static let oshiReaderEncryptedBackup = UTType(exportedAs: "com.otterpia.oshireader.encrypted-backup", conformingTo: .data)
}
