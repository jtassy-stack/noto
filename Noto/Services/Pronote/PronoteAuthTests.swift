import Foundation

/// Standalone validation of the Pronote crypto pipeline.
/// Run via: PronoteAuthTests.runAll() — prints PASS/FAIL to console.
/// No server needed — tests pure crypto logic.
enum PronoteAuthTests {

    static func runAll() {
        testSHA256()
        testHexConversions()
        testKeyDerivation()
        testAESRoundtrip()
        testChallengeResolution()
        testSessionKeyParsing()
        print("✅ All Pronote auth tests completed")
    }

    // MARK: - SHA-256

    static func testSHA256() {
        // Known test vector: SHA256("abc") = ba7816bf...
        let result = PronoteCrypto.sha256("abc")
        let expected = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        assert(result == expected, "SHA256 failed: got \(result)")
        print("  ✓ SHA-256")
    }

    // MARK: - Hex Conversions

    static func testHexConversions() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        assert(data.hexString == "deadbeef", "hexString lowercase failed")
        assert(data.hexStringUppercase == "DEADBEEF", "hexStringUppercase failed")

        let roundtrip = Data(hexString: "DEADBEEF")
        assert(roundtrip == data, "hexString roundtrip failed")

        print("  ✓ Hex conversions")
    }

    // MARK: - Key Derivation

    static func testKeyDerivation() {
        // Test that key derivation produces deterministic output
        let key1 = PronoteCrypto.deriveAuthKey(username: "parent1", password: "pass123", alea: "randomalea")
        let key2 = PronoteCrypto.deriveAuthKey(username: "parent1", password: "pass123", alea: "randomalea")
        assert(key1 == key2, "Key derivation not deterministic")

        // Key should start with username
        let keyString = String(data: key1, encoding: .utf8)!
        assert(keyString.hasPrefix("parent1"), "Key should start with username, got: \(keyString.prefix(20))")

        // Key should contain 64-char hex hash after username
        let hashPart = String(keyString.dropFirst("parent1".count))
        assert(hashPart.count == 64, "Hash part should be 64 hex chars, got \(hashPart.count)")
        assert(hashPart == hashPart.uppercased(), "Hash should be uppercase")

        // Different alea → different key
        let key3 = PronoteCrypto.deriveAuthKey(username: "parent1", password: "pass123", alea: "differentalea")
        assert(key1 != key3, "Different alea should produce different key")

        print("  ✓ Key derivation")
    }

    // MARK: - AES Roundtrip

    static func testAESRoundtrip() {
        // Test AES-128
        let key128 = Data(repeating: 0x42, count: 16)
        let iv = Data(repeating: 0x00, count: 16)
        let plaintext = "Hello Pronote!".data(using: .utf8)!

        let encrypted = try! PronoteCrypto.aesEncrypt(data: plaintext, key: key128, iv: iv)
        let decrypted = try! PronoteCrypto.aesDecrypt(data: encrypted, key: key128, iv: iv)
        assert(decrypted == plaintext, "AES-128 roundtrip failed")

        // Test AES-256
        let key256 = Data(repeating: 0x42, count: 32)
        let encrypted256 = try! PronoteCrypto.aesEncrypt(data: plaintext, key: key256, iv: iv)
        let decrypted256 = try! PronoteCrypto.aesDecrypt(data: encrypted256, key: key256, iv: iv)
        assert(decrypted256 == plaintext, "AES-256 roundtrip failed")

        // Different key sizes produce different ciphertext
        assert(encrypted != encrypted256, "AES-128 and AES-256 should differ")

        print("  ✓ AES roundtrip (128 + 256)")
    }

    // MARK: - Challenge Resolution

    static func testChallengeResolution() {
        // Simulate a challenge:
        // 1. Create a known plaintext challenge
        // 2. Encrypt it with a known key
        // 3. Solve it
        // 4. Verify the solution matches expected output

        let key = Data(repeating: 0xAB, count: 32)
        let iv = Data(repeating: 0xCD, count: 16)

        // Create a challenge: encrypt plaintext with Pronote's MD5-hashed AES
        let challengePlaintext = "A1B2C3D4E5F6G7H8"
        let challengeHex = try! PronoteCrypto.pronoteEncrypt(data: Data(challengePlaintext.utf8), key: key, iv: iv)

        // Solve: pronoteDecrypt → keep even indices → pronoteEncrypt
        let solvedHex = try! PronoteCrypto.solveChallenge(challengeHex: challengeHex, key: key, iv: iv)

        // Verify by decrypting the solution
        let solvedDecrypted = try! PronoteCrypto.pronoteDecrypt(hex: solvedHex, key: key, iv: iv)
        let solvedString = String(data: solvedDecrypted, encoding: .utf8)!

        // Even indices of "A1B2C3D4E5F6G7H8" → "ABCDEFGH"
        assert(solvedString == "ABCDEFGH", "Challenge resolution failed: got '\(solvedString)', expected 'ABCDEFGH'")

        print("  ✓ Challenge resolution")
    }

    // MARK: - Session Key Parsing

    static func testSessionKeyParsing() {
        // Comma-separated ASCII codes → bytes
        let result = PronoteCrypto.parseSessionKey(commaSeparated: "65,66,67,68")
        assert(result == Data([0x41, 0x42, 0x43, 0x44]), "Session key parsing failed")

        let str = String(data: result!, encoding: .utf8)
        assert(str == "ABCD", "Session key string failed: got \(str ?? "nil")")

        // Edge case: single byte
        let single = PronoteCrypto.parseSessionKey(commaSeparated: "90")
        assert(single == Data([90]), "Single byte parsing failed")

        // Edge case: empty
        let empty = PronoteCrypto.parseSessionKey(commaSeparated: "")
        assert(empty == nil || empty?.isEmpty == true, "Empty should return nil")

        print("  ✓ Session key parsing")
    }
}
