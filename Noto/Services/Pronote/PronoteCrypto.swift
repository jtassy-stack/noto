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

    // MARK: - Pronote AES (MD5-hashed key and IV)
    // Pronote's custom AES: key=MD5(rawKey), iv=MD5(rawIV) or zeros if empty

    static func pronoteEncrypt(data: Data, key: Data, iv: Data) throws -> String {
        let hashedKey = md5(key)
        let hashedIV = iv.isEmpty ? Data(count: 16) : md5(iv)
        let encrypted = try aesEncrypt(data: data, key: hashedKey, iv: hashedIV)
        return encrypted.hexString
    }

    static func pronoteDecrypt(hex: String, key: Data, iv: Data) throws -> Data {
        guard let cipherData = Data(hexString: hex) else {
            throw PronoteError.encryptionFailed("Invalid hex for decryption")
        }
        let hashedKey = md5(key)
        let hashedIV = iv.isEmpty ? Data(count: 16) : md5(iv)
        return try aesDecrypt(data: cipherData, key: hashedKey, iv: hashedIV)
    }

    // MARK: - MD5

    static func md5(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { dataPtr in
            hash.withUnsafeMutableBytes { hashPtr in
                _ = CC_MD5(dataPtr.baseAddress, CC_LONG(data.count), hashPtr.baseAddress?.assumingMemoryBound(to: UInt8.self))
            }
        }
        return hash
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
    /// Uses Pronote's MD5-hashed AES: decrypt challenge hex → keep even chars → re-encrypt
    static func solveChallenge(challengeHex: String, key: Data, iv: Data) throws -> String {
        // Decrypt (pronoteDecrypt handles MD5 hashing of key/iv)
        let decryptedBytes = try pronoteDecrypt(hex: challengeHex, key: key, iv: iv)

        // node-forge decodeUtf8 on the raw bytes
        guard let decryptedString = String(data: decryptedBytes, encoding: .utf8) else {
            throw PronoteError.encryptionFailed("Challenge decryption produced invalid UTF-8")
        }

        // Keep every other character (even indices: 0, 2, 4, ...)
        var filtered: [Character] = []
        for (index, char) in decryptedString.enumerated() where index.isMultiple(of: 2) {
            filtered.append(char)
        }
        let filteredString = String(filtered)

        // Re-encrypt (pronoteEncrypt handles MD5 hashing)
        let filteredData = Data(filteredString.utf8)
        return try pronoteEncrypt(data: filteredData, key: key, iv: iv)
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

    // MARK: - Compression

    /// Raw deflate (no zlib/gzip header) — matches pako.deflateRaw(data, {level: 6})
    static func deflateRaw(_ data: Data) throws -> Data {
        let nsData = data as NSData
        guard let compressed = try? nsData.compressed(using: .zlib) as Data else {
            throw PronoteError.encryptionFailed("Compression failed")
        }
        // NSData.compressed uses zlib format (header+data+checksum)
        // Strip 2-byte zlib header and 4-byte checksum for raw deflate
        guard compressed.count > 6 else { return compressed }
        return compressed.subdata(in: 2..<(compressed.count - 4))
    }

    /// Raw inflate — inverse of deflateRaw
    static func inflateRaw(_ data: Data) throws -> Data {
        // Add zlib header (78 01 = default compression) and dummy checksum for NSData
        var zlibData = Data([0x78, 0x01])
        zlibData.append(data)
        // Compute Adler-32 checksum
        let checksum = adler32(data)
        zlibData.append(UInt8((checksum >> 24) & 0xFF))
        zlibData.append(UInt8((checksum >> 16) & 0xFF))
        zlibData.append(UInt8((checksum >> 8) & 0xFF))
        zlibData.append(UInt8(checksum & 0xFF))

        let nsData = zlibData as NSData
        guard let decompressed = try? nsData.decompressed(using: .zlib) as Data else {
            throw PronoteError.encryptionFailed("Decompression failed")
        }
        return decompressed
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
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
