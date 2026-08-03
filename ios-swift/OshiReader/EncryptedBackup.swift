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
    static let currentVersion: UInt8 = 1
    static let saltLength = 16
    static let keyLength = 32
    static let iterations = 150_000
    static let maximumPasswordLength = 256
    static let maximumEnvelopeBytes = LocalDB.maximumBackupBytes + 512

    private static let headerLength = magic.count + 4

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
        let key = try deriveKey(password: password, salt: salt)
        let nonce = AES.GCM.Nonce()
        let header = makeHeader(version: currentVersion, saltLength: salt.count, nonceLength: 12, tagLength: 16)
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
        guard envelope.count >= headerLength else { throw EncryptedBackupError.invalidEnvelope }
        guard Data(envelope.prefix(magic.count)) == magic else { throw EncryptedBackupError.invalidEnvelope }

        let version = envelope[magic.count]
        guard version == currentVersion else { throw EncryptedBackupError.unsupportedVersion }
        let saltLength = Int(envelope[magic.count + 1])
        let nonceLength = Int(envelope[magic.count + 2])
        let tagLength = Int(envelope[magic.count + 3])
        guard saltLength == Self.saltLength,
              nonceLength == 12,
              tagLength == 16,
              envelope.count <= maximumEnvelopeBytes else {
            throw EncryptedBackupError.invalidEnvelope
        }

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
        let key = try deriveKey(password: password, salt: salt)
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

    private static func makeHeader(version: UInt8, saltLength: Int, nonceLength: Int, tagLength: Int) -> Data {
        var header = magic
        header.append(version)
        header.append(UInt8(saltLength))
        header.append(UInt8(nonceLength))
        header.append(UInt8(tagLength))
        return header
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw EncryptedBackupError.keyDerivationFailed }
        return Data(bytes)
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
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
