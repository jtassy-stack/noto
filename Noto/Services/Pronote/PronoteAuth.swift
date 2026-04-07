import Foundation

/// Handles Pronote authentication flows.
/// All crypto on-device — credentials never leave the phone.
enum PronoteAuth {

    // MARK: - Session Initialization

    /// Fetch mobile.parent.html and parse Start() to get session parameters.
    static func fetchSessionParams(
        baseURL: URL,
        accountKind: PronoteAccountKind
    ) async throws -> PronoteSession.SessionParams {
        // Build URL: {base}/mobile.{kind}.html?fd=1&login=true
        let pageName = "mobile.\(accountKind.path).html"
        var components = URLComponents(url: baseURL.appendingPathComponent(pageName), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fd", value: "1"),
            URLQueryItem(name: "login", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("appliMobile=1", forHTTPHeaderField: "Cookie")

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let html = String(data: data, encoding: .utf8) else {
            throw PronoteError.invalidResponse("Cannot read HTML page")
        }

        // Extract version from: >PRONOTE x.y.z<
        let version: [Int]
        if let versionMatch = html.range(of: #"PRONOTE (\d+\.\d+\.\d+)"#, options: .regularExpression) {
            let versionStr = String(html[versionMatch]).replacingOccurrences(of: "PRONOTE ", with: "")
            version = versionStr.split(separator: ".").compactMap { Int($0) }
        } else {
            version = [2024, 0, 0]
        }

        // Extract Start({...}) JSON from HTML
        // Format: Start({key: value, ...}) — keys are unquoted
        // Try multiple patterns — Pronote versions vary
        let startPatterns = ["{Start", "Start(", "start("]
        var startIdx: Range<String.Index>?
        for pattern in startPatterns {
            if let found = html.range(of: pattern) {
                startIdx = found
                break
            }
        }

        guard let startIdx else {
            // Debug: search for any occurrence of "Start" to help diagnose
            if let startRange = html.range(of: "Start", options: .caseInsensitive) {
                let contextStart = html.index(startRange.lowerBound, offsetBy: -20, limitedBy: html.startIndex) ?? html.startIndex
                let contextEnd = html.index(startRange.upperBound, offsetBy: 80, limitedBy: html.endIndex) ?? html.endIndex
                let context = String(html[contextStart..<contextEnd])
                throw PronoteError.invalidResponse("Found 'Start' but not pattern. Context: \(context)")
            }
            let preview = String(html.prefix(500))
            throw PronoteError.invalidResponse("Cannot find Start() in HTML. Preview: \(preview)")
        }

        // Find the opening paren after "Start" or "Start "
        let searchStart = startIdx.upperBound
        guard let openParen = html.range(of: "(", range: searchStart..<html.endIndex) else {
            throw PronoteError.invalidResponse("Cannot find opening paren of Start()")
        }
        let argsStart = openParen.upperBound

        // Find matching closing paren — track nesting depth
        var depth = 1
        var endOffset = argsStart
        for idx in html[argsStart...].indices {
            let ch = html[idx]
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1; if depth == 0 { endOffset = idx; break } }
        }

        guard depth == 0 else {
            throw PronoteError.invalidResponse("Cannot find end of Start() call")
        }

        let rawJSON = String(html[argsStart..<endOffset])
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")

        // Fix JS object to valid JSON: unquoted keys → quoted keys
        // {h:3451315,a:7,MR:"...",ER:"..."} → {"h":3451315,"a":7,"MR":"...","ER":"..."}
        let cleanedJSON = rawJSON.replacingOccurrences(
            of: #"([{,])([a-zA-Z_][a-zA-Z0-9_]*):"#,
            with: "$1\"$2\":",
            options: .regularExpression
        ).replacingOccurrences(of: "'", with: "\"")

        guard let jsonData = cleanedJSON.data(using: .utf8),
              let params = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw PronoteError.invalidResponse("Cannot parse Start() params. Raw: \(rawJSON.prefix(200))")
        }

        // Parse session params (matches W() in pawnote)
        let sessionId = params["h"] as? Int ?? (Int(params["h"] as? String ?? "0") ?? 0)
        let skipEncryption: Bool
        let skipCompression: Bool

        if params["MR"] == nil && params["ER"] == nil {
            // Modern Pronote (2023+): hardcoded RSA, no server-provided keys
            skipEncryption = !(params["CrA"] as? Bool ?? true)
            skipCompression = !(params["CoA"] as? Bool ?? true)
        } else {
            skipEncryption = params["sCrA"] as? Bool ?? false
            skipCompression = params["sCoA"] as? Bool ?? false
        }

        // Generate random IV (client-side, like pawnote)
        var ivBytes = Data(count: 16)
        _ = ivBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        return PronoteSession.SessionParams(
            sessionId: sessionId,
            aesIV: ivBytes,
            skipEncryption: skipEncryption,
            skipCompression: skipCompression,
            version: version
        )
    }

    // MARK: - QR Code Login

    static func loginWithQRCode(
        session: PronoteSession,
        qrData: [String: Any],
        pin: String,
        deviceUUID: String
    ) async throws -> PronoteRefreshToken {
        // 1. Parse QR
        let qrURL = qrData["url"] as? String ?? ""
        let encryptedLogin = qrData["login"] as? String ?? ""
        let encryptedToken = qrData["jeton"] as? String ?? ""

        // Extract account kind from URL
        let accountKind: PronoteAccountKind
        if qrURL.contains("parent") { accountKind = .parent }
        else if qrURL.contains("eleve") { accountKind = .student }
        else { accountKind = .parent }

        // Extract base URL (strip the last path component like "mobile.parent.html")
        let baseURL: String
        if let lastSlash = qrURL.lastIndex(of: "/") {
            baseURL = String(qrURL[qrURL.startIndex..<lastSlash])
        } else {
            baseURL = qrURL
        }

        guard let base = URL(string: baseURL) else {
            throw PronoteError.invalidResponse("Invalid QR URL: \(baseURL)")
        }

        // 2. Decrypt QR fields with PIN
        let pinKey = Data(pin.utf8)
        let emptyIV = Data()

        let username = try PronoteCrypto.pronoteDecrypt(hex: encryptedLogin, key: pinKey, iv: emptyIV)
        let token = try PronoteCrypto.pronoteDecrypt(hex: encryptedToken, key: pinKey, iv: emptyIV)

        guard let usernameStr = String(data: username, encoding: .utf8),
              let tokenStr = String(data: token, encoding: .utf8) else {
            throw PronoteError.badCredentials
        }

        // 3. Set correct base URL and account kind on session
        await session.setBaseURL(base)
        await session.setAccountKind(accountKind)

        // 4. Fetch session params from HTML page
        let params = try await fetchSessionParams(baseURL: base, accountKind: accountKind)
        await session.initializeSession(params: params)

        // 4. Identification with QR flags
        let identPayload: [String: Any] = [
            "donnees": [
                "genreConnexion": 0,
                "genreEspace": accountKind.rawValue,
                "identifiant": usernameStr,
                "pourENT": false,
                "enConnexionAuto": false,
                "demandeConnexionAuto": false,
                "enConnexionAppliMobile": false,
                "demandeConnexionAppliMobile": true,
                "demandeConnexionAppliMobileJeton": true,
                "uuidAppliMobile": deviceUUID,
                "loginTokenSAV": "",
            ]
        ]

        let identResponse = try await session.request(function: "Identification", payload: identPayload)

        guard let identData = identResponse["donneesSec"] as? [String: Any]
                ?? identResponse as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing identification data")
        }

        let alea = identData["alea"] as? String ?? ""
        let challengeHex = identData["challenge"] as? String ?? ""
        let modeCompLog = identData["modeCompLog"] as? Int ?? 0
        let modeCompMdp = identData["modeCompMdp"] as? Int ?? 0

        // 5. Normalize and derive key
        var normUsername = usernameStr
        var normToken = tokenStr
        if modeCompLog == 1 { normUsername = normUsername.lowercased() }
        if modeCompMdp == 1 { normToken = normToken.lowercased() }

        // Pe: key = createBuffer(username + SHA256(alea + encodeUtf8(token)).hex().upper())
        let authKey = PronoteCrypto.deriveAuthKey(
            username: normUsername,
            password: normToken,
            alea: alea
        )

        // 6. Solve challenge
        let aesIV = await session.getAESIV()
        let solvedChallenge = try PronoteCrypto.solveChallenge(
            challengeHex: challengeHex,
            key: authKey,
            iv: aesIV
        )

        // 7. Authenticate
        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge,
                "espace": accountKind.rawValue,
            ]
        ]

        let authResponse = try await session.request(function: "Authentification", payload: authPayload)

        guard let authData = authResponse["donneesSec"] as? [String: Any]
                ?? authResponse as? [String: Any] else {
            throw PronoteError.badCredentials
        }

        if let acces = authData["Acces"] as? Int, acces != 0 {
            throw PronoteError.badCredentials
        }

        // 8. Extract session key: Ie
        if let cleHex = authData["cle"] as? String {
            let decryptedCle = try PronoteCrypto.pronoteDecrypt(hex: cleHex, key: authKey, iv: aesIV)
            if let cleString = String(data: decryptedCle, encoding: .utf8),
               let parsed = PronoteCrypto.parseSessionKey(commaSeparated: cleString) {
                await session.setAESKey(parsed)
            } else {
                await session.setAESKey(decryptedCle)
            }
        }

        // 9. Check if double auth required (QR first-time → may need to call loginToken next)
        let hasDoubleAuth = authData["actionsDoubleAuth"] != nil
        let newToken = authData["jetonConnexionAppliMobile"] as? String ?? ""
        let loginFromIdent = identData["login"] as? String

        if hasDoubleAuth {
            // Pronote wants us to do a second auth via loginToken
            return try await loginWithToken(
                session: session,
                username: loginFromIdent ?? normUsername,
                token: newToken,
                deviceUUID: deviceUUID
            )
        }

        // Extract tabs and children
        await configureSessionFromAuth(session: session, authData: authData)

        return PronoteRefreshToken(
            url: baseURL,
            token: newToken,
            username: normUsername,
            kind: accountKind
        )
    }

    // MARK: - Login with Credentials

    static func loginWithCredentials(
        session: PronoteSession,
        username: String,
        password: String,
        deviceUUID: String
    ) async throws -> PronoteRefreshToken {
        let baseURL = await session.baseURL
        let accountKind = await session.accountKind

        // 1. Fetch session params
        let params = try await fetchSessionParams(baseURL: baseURL, accountKind: accountKind)
        await session.initializeSession(params: params)

        // 2. Identification
        let identPayload: [String: Any] = [
            "donnees": [
                "genreConnexion": 0,
                "genreEspace": accountKind.rawValue,
                "identifiant": username,
                "pourENT": false,
                "enConnexionAuto": false,
                "demandeConnexionAuto": true,
                "enConnexionAppliMobile": false,
                "demandeConnexionAppliMobile": true,
                "demandeConnexionAppliMobileJeton": false,
                "uuidAppliMobile": deviceUUID,
                "loginTokenSAV": "",
            ]
        ]

        let identResponse = try await session.request(function: "Identification", payload: identPayload)

        guard let identData = identResponse["donneesSec"] as? [String: Any]
                ?? identResponse as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing identification data")
        }

        let alea = identData["alea"] as? String ?? ""
        let challengeHex = identData["challenge"] as? String ?? ""
        let modeCompLog = identData["modeCompLog"] as? Int ?? 0
        let modeCompMdp = identData["modeCompMdp"] as? Int ?? 0

        // 3. Derive key and solve challenge
        let normUser = modeCompLog == 1 ? username.lowercased() : username
        let normPass = modeCompMdp == 1 ? password.lowercased() : password

        let authKey = PronoteCrypto.deriveAuthKey(username: normUser, password: normPass, alea: alea)
        let aesIV = await session.getAESIV()
        let solvedChallenge = try PronoteCrypto.solveChallenge(challengeHex: challengeHex, key: authKey, iv: aesIV)

        // 4. Authenticate
        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge,
                "espace": accountKind.rawValue,
            ]
        ]

        let authResponse = try await session.request(function: "Authentification", payload: authPayload)

        guard let authData = authResponse["donneesSec"] as? [String: Any]
                ?? authResponse as? [String: Any] else {
            throw PronoteError.badCredentials
        }

        if let acces = authData["Acces"] as? Int, acces != 0 {
            throw PronoteError.badCredentials
        }

        // 5. Extract session key
        if let cleHex = authData["cle"] as? String {
            let decryptedCle = try PronoteCrypto.pronoteDecrypt(hex: cleHex, key: authKey, iv: aesIV)
            if let cleString = String(data: decryptedCle, encoding: .utf8),
               let parsed = PronoteCrypto.parseSessionKey(commaSeparated: cleString) {
                await session.setAESKey(parsed)
            } else {
                await session.setAESKey(decryptedCle)
            }
        }

        await configureSessionFromAuth(session: session, authData: authData)

        let token = authData["jetonConnexionAppliMobile"] as? String ?? ""
        return PronoteRefreshToken(
            url: baseURL.absoluteString,
            token: token,
            username: username,
            kind: accountKind
        )
    }

    // MARK: - Login with Token (Reconnection)

    static func loginWithToken(
        session: PronoteSession,
        username: String,
        token: String,
        deviceUUID: String
    ) async throws -> PronoteRefreshToken {
        let baseURL = await session.baseURL
        let accountKind = await session.accountKind

        // Fetch session params if not already initialized
        if await session.sessionId == 0 {
            let params = try await fetchSessionParams(baseURL: baseURL, accountKind: accountKind)
            await session.initializeSession(params: params)
        }

        let identPayload: [String: Any] = [
            "donnees": [
                "genreConnexion": 0,
                "genreEspace": accountKind.rawValue,
                "identifiant": username,
                "pourENT": false,
                "enConnexionAuto": true,
                "demandeConnexionAuto": false,
                "enConnexionAppliMobile": true,
                "demandeConnexionAppliMobile": true,
                "demandeConnexionAppliMobileJeton": false,
                "jetonConnexionAppli": token,
                "uuidAppliMobile": deviceUUID,
                "loginTokenSAV": "",
            ]
        ]

        let identResponse = try await session.request(function: "Identification", payload: identPayload)

        guard let identData = identResponse["donneesSec"] as? [String: Any]
                ?? identResponse as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing identification data")
        }

        let alea = identData["alea"] as? String ?? ""
        let challengeHex = identData["challenge"] as? String ?? ""

        let authKey = PronoteCrypto.deriveAuthKey(username: username, password: token, alea: alea)
        let aesIV = await session.getAESIV()
        let solvedChallenge = try PronoteCrypto.solveChallenge(challengeHex: challengeHex, key: authKey, iv: aesIV)

        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge,
                "espace": accountKind.rawValue,
            ]
        ]

        let authResponse = try await session.request(function: "Authentification", payload: authPayload)

        guard let authData = authResponse["donneesSec"] as? [String: Any]
                ?? authResponse as? [String: Any] else {
            throw PronoteError.badCredentials
        }

        if let cleHex = authData["cle"] as? String {
            let decryptedCle = try PronoteCrypto.pronoteDecrypt(hex: cleHex, key: authKey, iv: aesIV)
            if let cleString = String(data: decryptedCle, encoding: .utf8),
               let parsed = PronoteCrypto.parseSessionKey(commaSeparated: cleString) {
                await session.setAESKey(parsed)
            } else {
                await session.setAESKey(decryptedCle)
            }
        }

        await configureSessionFromAuth(session: session, authData: authData)

        let newToken = authData["jetonConnexionAppliMobile"] as? String ?? ""
        return PronoteRefreshToken(
            url: baseURL.absoluteString,
            token: newToken,
            username: username,
            kind: accountKind
        )
    }

    // MARK: - Helpers

    private static func configureSessionFromAuth(session: PronoteSession, authData: [String: Any]) async {
        var tabs = Set<PronoteTab>()
        if let tabList = authData["listeOnglets"] as? [[String: Any]] {
            for tab in tabList {
                if let g = tab["G"] as? Int, let t = PronoteTab(rawValue: g) {
                    tabs.insert(t)
                }
            }
        }

        var children: [PronoteChildResource] = []
        if let resources = authData["ressource"] as? [[String: Any]] {
            for res in resources {
                children.append(PronoteChildResource(
                    id: res["N"] as? String ?? "",
                    name: res["L"] as? String ?? "",
                    className: res["classeDEleve"] as? String ?? "",
                    establishment: res["Etablissement"] as? String ?? ""
                ))
            }
        }

        let aesKey = await session.getAESKey()
        let aesIV = await session.getAESIV()
        await session.configure(
            sessionId: await session.sessionId,
            aesKey: aesKey,
            aesIV: aesIV,
            authorizedTabs: tabs,
            childResources: children
        )
    }
}
