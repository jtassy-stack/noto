import Foundation

/// Handles Pronote authentication: the full 7-step login flow.
/// Credentials never leave the device — challenge proves password knowledge
/// without transmitting it.
///
/// Flow:
/// 1. POST sessioninformation → get aesIV
/// 2. POST identification → get alea, challenge, cle, modeComp*
/// 3. Normalize credentials (case rules)
/// 4. Derive AES key: SHA256(alea + password).hex().uppercase() + username
/// 5. Solve challenge: decrypt → keep every other char → re-encrypt
/// 6. POST authentification → server validates
/// 7. Extract session key from encrypted `cle` field
enum PronoteAuth {

    // MARK: - Login with Credentials

    static func loginWithCredentials(
        session: PronoteSession,
        username: String,
        password: String,
        deviceUUID: String
    ) async throws -> PronoteRefreshToken {
        let baseURL = await session.baseURL
        let accountPath = await session.accountKind.path

        // Step 1: Session Information
        let sessionInfo = try await postFunction(
            baseURL: baseURL,
            path: accountPath,
            function: "FonctionParametres",
            order: 0,
            payload: ["Uuid": deviceUUID]
        )

        guard let donnees = sessionInfo["donneesSec"] as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing donneesSec in session info")
        }

        let aesIVHex = donnees["Nonce"] as? String ?? ""
        guard let aesIV = Data(hexString: aesIVHex), aesIV.count == 16 else {
            throw PronoteError.encryptionFailed("Invalid IV from server: \(aesIVHex)")
        }

        let sessionId = donnees["Session"] as? Int ?? 0

        // Step 2: Identification
        let identPayload: [String: Any] = [
            "donnees": [
                "Identifiant": username,
                "PourENT": false,
                "enConnexionAuto": false,
                "demandeConnexionAuto": true,
                "demandeConnexionAppli": true,
                "demandeConnexionAppliAvec498": true,
                "Connecteur": 0,
                "espace": await session.accountKind.rawValue,
            ]
        ]

        let identResponse = try await postFunction(
            baseURL: baseURL,
            path: accountPath,
            function: "Identification",
            order: 2,
            payload: identPayload
        )

        guard let identData = identResponse["donneesSec"] as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing donneesSec in identification")
        }

        let alea = identData["alea"] as? String ?? ""
        let challengeHex = identData["challenge"] as? String ?? ""
        let modeCompLog = identData["modeCompLog"] as? Int ?? 0
        let modeCompMdp = identData["modeCompMdp"] as? Int ?? 0

        // Step 3: Normalize credentials
        let normalizedUsername = normalizeCredential(username, mode: modeCompLog)
        let normalizedPassword = normalizeCredential(password, mode: modeCompMdp)

        // Step 4: Derive AES key
        // Pe=(e,s,t) => sha256(alea + encodeUtf8(token)).toHex().toUpperCase() → createBuffer(username + hash)
        let authKey = PronoteCrypto.deriveAuthKey(
            username: normalizedUsername,
            password: normalizedPassword,
            alea: alea
        )

        // Step 5: Solve challenge (uses Pronote's MD5-hashed AES)
        let solvedChallenge = try PronoteCrypto.solveChallenge(
            challengeHex: challengeHex,
            key: authKey,
            iv: aesIV
        )

        // Step 6: Authenticate
        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge,
                "espace": await session.accountKind.rawValue,
            ]
        ]

        let authResponse = try await postFunction(
            baseURL: baseURL,
            path: accountPath,
            function: "Authentification",
            order: 4,
            payload: authPayload
        )

        // Check for errors
        if let erreur = authResponse["Erreur"] as? [String: Any],
           let code = erreur["G"] as? Int {
            switch code {
            case 22: throw PronoteError.badCredentials
            case 73, 74: throw PronoteError.suspendedIP
            case 20: throw PronoteError.rateLimited
            default: throw PronoteError.invalidResponse("Error code \(code)")
            }
        }

        guard let authData = authResponse["donneesSec"] as? [String: Any] else {
            throw PronoteError.badCredentials
        }

        // Step 7: Extract session key
        let sessionKey: Data
        if let cleHex = authData["cle"] as? String {
            // Decrypt cle with auth key using Pronote's MD5-hashed AES
            let decryptedCle = try PronoteCrypto.pronoteDecrypt(hex: cleHex, key: authKey, iv: aesIV)
            if let cleString = String(data: decryptedCle, encoding: .utf8),
               let parsed = PronoteCrypto.parseSessionKey(commaSeparated: cleString) {
                sessionKey = parsed
            } else {
                sessionKey = decryptedCle
            }
        } else {
            throw PronoteError.encryptionFailed("Missing session key in auth response")
        }

        // Extract authorized tabs
        var tabs = Set<PronoteTab>()
        if let tabList = authData["listeOnglets"] as? [[String: Any]] {
            for tab in tabList {
                if let g = tab["G"] as? Int, let pronoteTab = PronoteTab(rawValue: g) {
                    tabs.insert(pronoteTab)
                }
            }
        }

        // Extract children (for parent accounts)
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

        // Configure session with new key
        await session.configure(
            sessionId: sessionId,
            aesKey: sessionKey,
            aesIV: aesIV,
            authorizedTabs: tabs,
            childResources: children
        )

        // Extract refresh token
        let token = authData["jetonConnexionAppli"] as? String ?? ""

        return PronoteRefreshToken(
            url: baseURL.absoluteString,
            token: token,
            username: username,
            kind: await session.accountKind
        )
    }

    // MARK: - Login with Token (Reconnection)

    static func loginWithToken(
        session: PronoteSession,
        username: String,
        token: String,
        deviceUUID: String
    ) async throws -> PronoteRefreshToken {
        // Token login follows the same flow but with:
        // - enConnexionAuto: true
        // - jetonConnexionAppli: token
        // - Password is replaced by the token for key derivation

        let baseURL = await session.baseURL
        let accountPath = await session.accountKind.path

        // Step 1: Session Information
        let sessionInfo = try await postFunction(
            baseURL: baseURL,
            path: accountPath,
            function: "FonctionParametres",
            order: 0,
            payload: ["Uuid": deviceUUID]
        )

        guard let donnees = sessionInfo["donneesSec"] as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing donneesSec")
        }

        let aesIVHex = donnees["Nonce"] as? String ?? ""
        guard let aesIV = Data(hexString: aesIVHex), aesIV.count == 16 else {
            throw PronoteError.encryptionFailed("Invalid IV")
        }

        let sessionId = donnees["Session"] as? Int ?? 0

        // Step 2: Identification with token
        let identPayload: [String: Any] = [
            "donnees": [
                "Identifiant": username,
                "PourENT": false,
                "enConnexionAuto": true,
                "enConnexionAppli": true,
                "demandeConnexionAppli": true,
                "demandeConnexionAppliAvec498": true,
                "jetonConnexionAppli": token,
                "Connecteur": 0,
                "espace": await session.accountKind.rawValue,
            ]
        ]

        let identResponse = try await postFunction(
            baseURL: baseURL,
            path: accountPath,
            function: "Identification",
            order: 2,
            payload: identPayload
        )

        guard let identData = identResponse["donneesSec"] as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing donneesSec in identification")
        }

        let alea = identData["alea"] as? String ?? ""
        let challengeHex = identData["challenge"] as? String ?? ""

        // For token login, the "password" in key derivation is the token
        let authKey = PronoteCrypto.deriveAuthKey(
            username: username,
            password: token,
            alea: alea
        )

        let solvedChallenge = try PronoteCrypto.solveChallenge(
            challengeHex: challengeHex,
            key: authKey,
            iv: aesIV
        )

        // Step 6: Authenticate
        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge,
                "espace": await session.accountKind.rawValue,
            ]
        ]

        let authResponse = try await postFunction(
            baseURL: baseURL,
            path: accountPath,
            function: "Authentification",
            order: 4,
            payload: authPayload
        )

        if let erreur = authResponse["Erreur"] as? [String: Any],
           let code = erreur["G"] as? Int {
            switch code {
            case 22: throw PronoteError.badCredentials
            default: throw PronoteError.invalidResponse("Error code \(code)")
            }
        }

        guard let authData = authResponse["donneesSec"] as? [String: Any] else {
            throw PronoteError.badCredentials
        }

        // Extract session key
        let sessionKey: Data
        if let cleHex = authData["cle"] as? String, let cleData = Data(hexString: cleHex) {
            let decryptedCle = try PronoteCrypto.aesDecrypt(data: cleData, key: authKey, iv: aesIV)
            if let cleString = String(data: decryptedCle, encoding: .utf8),
               let parsed = PronoteCrypto.parseSessionKey(commaSeparated: cleString) {
                sessionKey = parsed
            } else {
                sessionKey = decryptedCle
            }
        } else {
            throw PronoteError.encryptionFailed("Missing session key")
        }

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

        await session.configure(
            sessionId: sessionId,
            aesKey: sessionKey,
            aesIV: aesIV,
            authorizedTabs: tabs,
            childResources: children
        )

        let newToken = authData["jetonConnexionAppli"] as? String ?? ""

        return PronoteRefreshToken(
            url: baseURL.absoluteString,
            token: newToken,
            username: username,
            kind: await session.accountKind
        )
    }

    // MARK: - Raw HTTP (pre-session, unencrypted)

    /// POST to appelfonction without session encryption (used during login handshake).
    /// These initial requests are unencrypted — encryption starts after auth completes.
    private static func postFunction(
        baseURL: URL,
        path: String,
        function: String,
        order: Int,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        let endpoint = baseURL.appendingPathComponent("appelfonction/\(path)")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "0"),
            URLQueryItem(name: "a", value: "\(order)"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let base64 = jsonData.base64EncodedString()
        let encoded = base64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? base64
        let body = "v=3&f=\(function)&d=\(encoded)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PronoteError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Initial responses are unencrypted JSON (or base64-encoded JSON)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Try base64 decode
        if let str = String(data: data, encoding: .utf8),
           let decoded = Data(base64Encoded: str),
           let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] {
            return json
        }

        throw PronoteError.invalidResponse("Cannot parse auth response")
    }

    // MARK: - Credential Normalization

    /// Apply Pronote's case-sensitivity rules.
    /// mode 0 = as-is, mode 1 = lowercase
    private static func normalizeCredential(_ value: String, mode: Int) -> String {
        mode == 1 ? value.lowercased() : value
    }

    // MARK: - QR Code Login

    /// Login with QR code data + PIN.
    /// PIN decrypts the QR fields, then standard auth flow with QR-specific flags.
    static func loginWithQRCode(
        session: PronoteSession,
        qrData: [String: Any],
        pin: String,
        deviceUUID: String
    ) async throws -> PronoteRefreshToken {
        // 1. Parse QR: extract URL, encrypted login/token
        let qrURL = qrData["url"] as? String ?? ""
        let encryptedLogin = qrData["login"] as? String ?? ""
        let encryptedToken = qrData["jeton"] as? String ?? ""

        // Extract account kind from URL path (e.g. "mobile.parent.html" → .parent)
        let accountKind: PronoteAccountKind
        if qrURL.contains("parent") {
            accountKind = .parent
        } else if qrURL.contains("eleve") {
            accountKind = .student
        } else {
            accountKind = .parent
        }

        // Extract base URL (everything before the last path component)
        let baseURL: String
        if let lastSlash = qrURL.lastIndex(of: "/") {
            baseURL = String(qrURL[qrURL.startIndex..<lastSlash])
        } else {
            baseURL = qrURL
        }

        // 2. Decrypt login and token with PIN as AES key
        // pawnote: se.decrypt(n.util.encodeUtf8(field), createBuffer(pin), createBuffer())
        // encodeUtf8 → converts string chars to hex bytes
        // createBuffer(pin) → raw PIN bytes as key
        // createBuffer() → empty IV (pronoteDecrypt uses zeros)
        let pinKey = Data(pin.utf8)
        let emptyIV = Data()

        func decryptField(_ hexValue: String) throws -> String {
            // QR fields are already hex-encoded ciphertext — pass directly
            let decrypted = try PronoteCrypto.pronoteDecrypt(hex: hexValue, key: pinKey, iv: emptyIV)
            guard let str = String(data: decrypted, encoding: .utf8) else {
                throw PronoteError.badCredentials
            }
            return str
        }

        let username = try decryptField(encryptedLogin)
        let token = try decryptField(encryptedToken)

        // 3. Get session info (same as credentials login)
        let sessionInfo = try await postFunction(
            baseURL: URL(string: baseURL)!,
            path: accountKind.path,
            function: "FonctionParametres",
            order: 0,
            payload: ["Uuid": deviceUUID]
        )

        guard let donnees = sessionInfo["donneesSec"] as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing donneesSec")
        }

        let aesIVHex = donnees["Nonce"] as? String ?? ""
        guard let aesIV = Data(hexString: aesIVHex), aesIV.count == 16 else {
            throw PronoteError.encryptionFailed("Invalid IV")
        }

        let sessionId = donnees["Session"] as? Int ?? 0

        // 4. Identification with QR-specific flags
        let identPayload: [String: Any] = [
            "donnees": [
                "Identifiant": username,
                "PourENT": false,
                "enConnexionAuto": false,
                "demandeConnexionAuto": false,
                "enConnexionAppliMobile": false,
                "demandeConnexionAppliMobile": true,
                "demandeConnexionAppliMobileJeton": true,  // QR flag
                "uuidAppliMobile": deviceUUID,
                "loginTokenSAV": "",
                "Connecteur": 0,
                "espace": accountKind.rawValue,
            ]
        ]

        let identResponse = try await postFunction(
            baseURL: URL(string: baseURL)!,
            path: accountKind.path,
            function: "Identification",
            order: 2,
            payload: identPayload
        )

        guard let identData = identResponse["donneesSec"] as? [String: Any] else {
            throw PronoteError.invalidResponse("Missing identification data")
        }

        let alea = identData["alea"] as? String ?? ""
        let challengeHex = identData["challenge"] as? String ?? ""
        let modeCompLog = identData["modeCompLog"] as? Int ?? 0
        let modeCompMdp = identData["modeCompMdp"] as? Int ?? 0

        // 5. Apply credential normalization
        var normUsername = username
        var normToken = token
        if modeCompLog == 1 { normUsername = normUsername.lowercased() }
        if modeCompMdp == 1 { normToken = normToken.lowercased() }

        // 6. Derive key: Pe = createBuffer(username + SHA256(alea + encodeUtf8(token)).hex().upper())
        let authKey = PronoteCrypto.deriveAuthKey(
            username: normUsername,
            password: normToken,
            alea: alea
        )

        // 7. Solve challenge
        let solvedChallenge = try PronoteCrypto.solveChallenge(
            challengeHex: challengeHex,
            key: authKey,
            iv: aesIV
        )

        // 8. Authenticate
        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge,
                "espace": accountKind.rawValue,
            ]
        ]

        let authResponse = try await postFunction(
            baseURL: URL(string: baseURL)!,
            path: accountKind.path,
            function: "Authentification",
            order: 4,
            payload: authPayload
        )

        if let erreur = authResponse["Erreur"] as? [String: Any],
           let code = erreur["G"] as? Int {
            switch code {
            case 22: throw PronoteError.badCredentials
            default: throw PronoteError.invalidResponse("Error code \(code)")
            }
        }

        guard let authData = authResponse["donneesSec"] as? [String: Any] else {
            throw PronoteError.badCredentials
        }

        // 9. Extract session key
        let sessionKey: Data
        if let cleHex = authData["cle"] as? String {
            let decryptedCle = try PronoteCrypto.pronoteDecrypt(hex: cleHex, key: authKey, iv: aesIV)
            if let cleString = String(data: decryptedCle, encoding: .utf8),
               let parsed = PronoteCrypto.parseSessionKey(commaSeparated: cleString) {
                sessionKey = parsed
            } else {
                sessionKey = decryptedCle
            }
        } else {
            throw PronoteError.encryptionFailed("Missing session key")
        }

        // Extract tabs and children
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

        await session.configure(
            sessionId: sessionId,
            aesKey: sessionKey,
            aesIV: aesIV,
            authorizedTabs: tabs,
            childResources: children
        )

        let newToken = authData["jetonConnexionAppliMobile"] as? String ?? ""

        return PronoteRefreshToken(
            url: baseURL,
            token: newToken,
            username: username,
            kind: accountKind
        )
    }
}
