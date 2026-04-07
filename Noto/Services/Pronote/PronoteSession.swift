import Foundation

/// Manages an active Pronote session: order counter, encryption, request dispatch.
actor PronoteSession {
    let baseURL: URL
    let accountKind: PronoteAccountKind

    private(set) var sessionId: Int = 0
    private(set) var order: Int = 0
    private var aesKey: Data?
    private var aesIV: Data?
    private var skipEncryption: Bool = false
    private var skipCompression: Bool = false
    private(set) var authorizedTabs: Set<PronoteTab> = []
    private(set) var childResources: [PronoteChildResource] = []
    private(set) var activeChildIndex: Int = 0

    private let urlSession: URLSession

    init(baseURL: URL, accountKind: PronoteAccountKind = .parent) {
        self.baseURL = baseURL
        self.accountKind = accountKind
        self.urlSession = URLSession(configuration: .ephemeral) // No disk cache
    }

    // MARK: - Session Setup

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
        self.order = 0
    }

    func setActiveChild(index: Int) {
        guard index < childResources.count else { return }
        activeChildIndex = index
    }

    // MARK: - Request Dispatch

    /// Send an encrypted request to Pronote's appelfonction endpoint.
    func request(function: String, payload: [String: Any]) async throws -> sending [String: Any] {
        guard let key = aesKey, let iv = aesIV else {
            throw PronoteError.encryptionFailed("Session not configured")
        }

        let currentOrder = order
        order += 2

        // Serialize payload
        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        // Compress + Encrypt
        var processedData = jsonData
        if !skipCompression {
            processedData = try PronoteCrypto.compress(processedData)
        }
        if !skipEncryption {
            processedData = try PronoteCrypto.aesEncrypt(data: processedData, key: key, iv: iv)
        }

        let base64Payload = processedData.base64EncodedString()

        // Build form-encoded body
        let endpoint = baseURL.appendingPathComponent("appelfonction/\(accountKind.path)")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "\(sessionId)"),
            URLQueryItem(name: "a", value: "\(currentOrder)"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "v=3&f=\(function)&d=\(base64Payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? base64Payload)"
        request.httpBody = body.data(using: .utf8)

        // Send
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PronoteError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw PronoteError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }

        // Decrypt + Decompress response
        var responseData = data
        if !skipEncryption {
            responseData = try PronoteCrypto.aesDecrypt(data: responseData, key: key, iv: iv)
        }
        if !skipCompression {
            responseData = try PronoteCrypto.decompress(responseData)
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw PronoteError.invalidResponse("Invalid JSON response")
        }

        return json
    }

    // MARK: - Tab Authorization

    func ensureTabAuthorized(_ tab: PronoteTab) throws {
        guard authorizedTabs.contains(tab) else {
            throw PronoteError.tabNotAuthorized(tab)
        }
    }
}

// MARK: - Child Resource

struct PronoteChildResource: Sendable {
    let id: String
    let name: String
    let className: String
    let establishment: String
}
