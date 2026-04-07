import Foundation
import CommonCrypto
import Security

/// Handles AES-CBC encryption/decryption (128 and 256-bit), RSA, SHA-256,
/// and compression for the Pronote protocol.
/// All crypto stays on-device — no keys are transmitted to third parties.
enum PronoteCrypto {

    // MARK: - AES-CBC (auto key size: 128 or 256 based on key length)

    static func aesEncrypt(data: Data, key: Data, iv: Data) throws -> Data {
        try aesCrypt(operation: CCOperation(kCCEncrypt), data: data, key: key, iv: iv)
    }

    static func aesDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        try aesCrypt(operation: CCOperation(kCCDecrypt), data: data, key: key, iv: iv)
    }

    private static func aesCrypt(operation: CCOperation, data: Data, key: Data, iv: Data) throws -> Data {
        // CCCrypt auto-selects AES-128/192/256 based on key size
        let keySize = key.count
        guard keySize == kCCKeySizeAES128 || keySize == kCCKeySizeAES192 || keySize == kCCKeySizeAES256 else {
            throw PronoteError.encryptionFailed("Invalid AES key size: \(keySize) bytes")
        }

        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesWritten = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keySize,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            bufferPtr.baseAddress, bufferSize,
                            &bytesWritten
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw PronoteError.encryptionFailed("AES failed with status \(status)")
        }

        return buffer.prefix(bytesWritten)
    }

    // MARK: - SHA-256

    static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        return sha256(data).hexStringUppercase
    }

    static func sha256(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { dataPtr in
            hash.withUnsafeMutableBytes { hashPtr in
                _ = CC_SHA256(dataPtr.baseAddress, CC_LONG(data.count), hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self))
            }
        }
        return hash
    }

    // MARK: - Pronote Challenge Resolution

    /// Derive the AES key for challenge resolution.
    /// Key = UTF-8 bytes of (username + SHA256(alea + password).hex().uppercase())
    static func deriveAuthKey(username: String, password: String, alea: String) -> Data {
        let hashData = sha256(Data((alea + password).utf8))
        let hexHash = hashData.hexStringUppercase // Uppercase hex
        let keyString = username + hexHash
        return Data(keyString.utf8)
    }

    /// Solve the Pronote authentication challenge.
    /// 1. Decrypt challenge with derived key
    /// 2. Keep every other character (indices 0, 2, 4, ...)
    /// 3. Re-encrypt with same key/IV
    static func solveChallenge(encrypted: Data, key: Data, iv: Data) throws -> Data {
        // Decrypt
        let decrypted = try aesDecrypt(data: encrypted, key: key, iv: iv)

        guard let decryptedString = String(data: decrypted, encoding: .utf8) else {
            throw PronoteError.encryptionFailed("Challenge decryption produced invalid UTF-8")
        }

        // Keep every other character (even indices: 0, 2, 4, ...)
        let filtered = String(decryptedString.enumerated()
            .filter { $0.offset.isMultiple(of: 2) }
            .map(\.element))

        // Re-encrypt
        guard let filteredData = filtered.data(using: .utf8) else {
            throw PronoteError.encryptionFailed("Challenge filter produced invalid UTF-8")
        }

        return try aesEncrypt(data: filteredData, key: key, iv: iv)
    }

    /// Parse session key from comma-separated ASCII decimal codes.
    /// e.g. "65,66,67,68" → Data([0x41, 0x42, 0x43, 0x44])
    static func parseSessionKey(commaSeparated: String) -> Data? {
        let codes = commaSeparated.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        guard !codes.isEmpty else { return nil }
        return Data(codes)
    }

    // MARK: - RSA

    /// RSA-encrypt data using modulus and exponent (for password during login).
    /// Pronote 2023+ uses hardcoded RSA-2048 constants.
    static func rsaEncrypt(data: Data, modulus: String, exponent: String) throws -> Data {
        guard let modData = Data(hexString: modulus),
              let expData = Data(hexString: exponent) else {
            throw PronoteError.encryptionFailed("Invalid RSA hex parameters")
        }

        let keyData = try buildDERPublicKey(modulus: modData, exponent: expData)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modData.count * 8,
        ]

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw PronoteError.encryptionFailed("Failed to create RSA key: \(error.debugDescription)")
        }

        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionPKCS1, data as CFData, &error) else {
            throw PronoteError.encryptionFailed("RSA encryption failed: \(error.debugDescription)")
        }

        return encrypted as Data
    }

    // MARK: - Compression (zlib via NSData)

    static func compress(_ data: Data) throws -> Data {
        let nsData = data as NSData
        guard let compressed = try? nsData.compressed(using: .zlib) as Data else {
            throw PronoteError.encryptionFailed("Compression failed")
        }
        return compressed
    }

    static func decompress(_ data: Data) throws -> Data {
        let nsData = data as NSData
        guard let decompressed = try? nsData.decompressed(using: .zlib) as Data else {
            throw PronoteError.encryptionFailed("Decompression failed")
        }
        return decompressed
    }

    // MARK: - DER Key Builder

    private static func buildDERPublicKey(modulus: Data, exponent: Data) throws -> Data {
        func derLength(_ length: Int) -> Data {
            if length < 0x80 {
                return Data([UInt8(length)])
            } else if length < 0x100 {
                return Data([0x81, UInt8(length)])
            } else {
                return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
            }
        }

        func derInteger(_ data: Data) -> Data {
            var bytes = Data(data)
            if let first = bytes.first, first & 0x80 != 0 {
                bytes.insert(0x00, at: 0)
            }
            return Data([0x02]) + derLength(bytes.count) + bytes
        }

        let modInt = derInteger(modulus)
        let expInt = derInteger(exponent)
        let sequence = modInt + expInt
        let innerSequence = Data([0x30]) + derLength(sequence.count) + sequence

        let bitString = Data([0x03]) + derLength(innerSequence.count + 1) + Data([0x00]) + innerSequence

        // RSA OID: 1.2.840.113549.1.1.1
        let oid = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])

        let outer = oid + bitString
        return Data([0x30]) + derLength(outer.count) + outer
    }
}

// MARK: - Data Hex Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var hexStringUppercase: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
