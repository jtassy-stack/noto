import Foundation

/// Manages an active Pronote session: handles the encrypted request/response protocol.
///
/// Pronote protocol:
/// 1. GET mobile.parent.html → parse Start() → session params
/// 2. Each request: POST JSON to appelfonction/{kind}/{sessionId}/{encryptedOrder}
/// 3. Order is incremented and encrypted per-request
/// 4. Data is optionally compressed (hex→deflate→hex) then encrypted
actor PronoteSession {
    private(set) var baseURL: URL
    private(set) var accountKind: PronoteAccountKind

    private(set) var sessionId: Int = 0
    private(set) var order: Int = 0
    private var aesKey: Data = Data()   // Starts empty
    private var aesIV: Data = Data()    // Set during session init
    private var skipEncryption: Bool = false
    private var skipCompression: Bool = false
    private(set) var authorizedTabs: Set<PronoteTab> = []
    private(set) var childResources: [PronoteChildResource] = []
    private(set) var activeChildIndex: Int = 0

    // Protocol version field names (differ between old/new Pronote)
    private var fieldNames = FieldNames.modern

    private let urlSession: URLSession

    init(baseURL: URL, accountKind: PronoteAccountKind = .parent) {
        self.baseURL = baseURL
        self.accountKind = accountKind
        self.urlSession = URLSession(configuration: .ephemeral)
    }

    // MARK: - Session Setup from HTML page

    struct SessionParams {
        let sessionId: Int
        let aesIV: Data
        let skipEncryption: Bool
        let skipCompression: Bool
        let version: [Int]
    }

    /// Initialize session from parsed Start() parameters.
    func initializeSession(params: SessionParams) {
        self.sessionId = params.sessionId
        self.aesIV = params.aesIV
        self.aesKey = Data() // Empty until auth completes
        self.skipEncryption = params.skipEncryption
        self.skipCompression = params.skipCompression
        self.order = 0
    }

    /// Configure session after successful authentication.
    func configure(
        sessionId: Int,
        aesKey: Data,
        aesIV: Data,
        authorizedTabs: Set<PronoteTab>,
        childResources: [PronoteChildResource],
        skipEncryption: Bool = false,
        skipCompression: Bool = false
    ) {
        self.sessionId = sessionId
        self.aesKey = aesKey
        self.aesIV = aesIV
        self.authorizedTabs = authorizedTabs
        self.childResources = childResources
        self.skipEncryption = skipEncryption
        self.skipCompression = skipCompression
    }

    func setActiveChild(index: Int) {
        guard index < childResources.count else { return }
        activeChildIndex = index
    }

    func setAESKey(_ key: Data) {
        self.aesKey = key
    }

    func setBaseURL(_ url: URL) {
        self.baseURL = url
    }

    func setAccountKind(_ kind: PronoteAccountKind) {
        self.accountKind = kind
    }

    func getAESIV() -> Data { aesIV }
    func getAESKey() -> Data { aesKey }

    // MARK: - Request Dispatch

    /// Send a request using Pronote's encrypted protocol.
    func request(function: String, payload: [String: Any]) async throws -> sending [String: Any] {
        // Increment order
        order += 1
        let currentOrder = order
        let isFirstRequest = currentOrder == 1

        // Get keys for this request
        let (key, iv) = requestKeys(isFirst: isFirstRequest)

        // Encrypt order number
        let orderString = String(currentOrder)
        let encryptedOrder = try PronoteCrypto.pronoteEncrypt(
            data: Data(orderString.utf8), key: key, iv: iv
        )

        // Prepare data
        var processedData: String
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        if !skipCompression {
            // Compress: UTF-8 → hex encode each byte → deflateRaw → hex encode result
            let hexOfUtf8 = Data(jsonString.utf8).map { String(format: "%02x", $0) }.joined()
            let compressed = try PronoteCrypto.deflateRaw(Data(hexOfUtf8.utf8))
            // Convert compressed bytes to hex string (via byte→char→hex)
            let compressedHex = compressed.map { String(format: "%02x", $0) }.joined()
            processedData = compressedHex
        } else {
            processedData = jsonString
        }

        if !skipEncryption {
            // Encrypt the processed data
            let dataToEncrypt: Data
            if !skipCompression {
                // Data is hex string → convert hex to raw bytes first
                guard let hexBytes = Data(hexString: processedData) else {
                    throw PronoteError.encryptionFailed("Invalid hex data for encryption")
                }
                dataToEncrypt = hexBytes
            } else {
                dataToEncrypt = Data(processedData.utf8)
            }
            processedData = try PronoteCrypto.pronoteEncrypt(data: dataToEncrypt, key: key, iv: iv)
        }

        // Build URL: {base}/appelfonction/{accountKind}/{sessionId}/{encryptedOrder}
        let endpoint = baseURL
            .appendingPathComponent("appelfonction")
            .appendingPathComponent(String(accountKind.rawValue))
            .appendingPathComponent(String(sessionId))
            .appendingPathComponent(encryptedOrder)

        // Build JSON body
        let body: [String: Any] = [
            fieldNames.session: sessionId,
            fieldNames.orderNumber: encryptedOrder,
            fieldNames.requestId: function,
            fieldNames.secureData: processedData,
        ]

        NSLog("[noto] REQUEST: \(function) → \(endpoint.absoluteString)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("appliMobile=1", forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? "empty"
            throw PronoteError.invalidResponse("HTTP \(code) for \(function). URL: \(endpoint.absoluteString). Body: \(body)")
        }

        // Parse response JSON
        guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PronoteError.invalidResponse("Invalid JSON response")
        }

        NSLog("[noto] RAW RESPONSE \(function): keys=\(responseJSON.keys.sorted())")

        // Decrypt response data
        guard let secureData = responseJSON[fieldNames.secureData] as? String else {
            // Response might not have encrypted data (e.g. errors)
            NSLog("[noto] No '\(fieldNames.secureData)' in response for \(function)")
            return responseJSON
        }

        var responseData: Data

        if !skipEncryption {
            responseData = try PronoteCrypto.pronoteDecrypt(hex: secureData, key: key, iv: iv)
        } else {
            responseData = Data(secureData.utf8)
        }

        if !skipCompression {
            // Decompress: hex → inflateRaw → hex decode
            responseData = try PronoteCrypto.inflateRaw(responseData)
            // Result is hex-encoded UTF-8 → decode hex pairs to bytes → UTF-8 string
            let hexString = String(data: responseData, encoding: .utf8) ?? ""
            if let decoded = Data(hexString: hexString) {
                responseData = decoded
            }
        }

        guard let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            let preview = String(data: responseData.prefix(300), encoding: .utf8) ?? "binary"
            NSLog("[noto] RESPONSE \(function): cannot parse JSON. Preview: \(preview)")
            throw PronoteError.invalidResponse("Cannot parse decrypted response for \(function)")
        }

        NSLog("[noto] RESPONSE \(function): \(result.keys.sorted())")
        return result
    }

    // MARK: - Tab Authorization

    func ensureTabAuthorized(_ tab: PronoteTab) throws {
        guard authorizedTabs.contains(tab) else {
            throw PronoteError.tabNotAuthorized(tab)
        }
    }

    // MARK: - Private

    /// Get AES key/IV for a request. First request uses empty key/IV.
    private func requestKeys(isFirst: Bool) -> (key: Data, iv: Data) {
        if isFirst {
            return (key: Data(), iv: Data()) // Empty → pronoteEncrypt will MD5("") = d41d8cd98f00b204e9800998ecf8427e
        }
        return (key: aesKey, iv: aesIV)
    }
}

// MARK: - Field Names

/// Pronote protocol field names (differ between versions)
private struct FieldNames {
    let session: String
    let orderNumber: String
    let secureData: String
    let requestId: String
    let signature: String

    /// Modern Pronote (2024+)
    static let modern = FieldNames(
        session: "session",
        orderNumber: "numeroOrdre",
        secureData: "donneesSec",
        requestId: "nom",
        signature: "Signature"
    )
}

// MARK: - Child Resource

struct PronoteChildResource: Sendable {
    let id: String
    let name: String
    let className: String
    let establishment: String
}
