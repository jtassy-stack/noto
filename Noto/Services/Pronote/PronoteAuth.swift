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

        guard let challengeData = Data(hexString: challengeHex) else {
            throw PronoteError.encryptionFailed("Invalid challenge hex")
        }

        // Step 3: Normalize credentials
        let normalizedUsername = normalizeCredential(username, mode: modeCompLog)
        let normalizedPassword = normalizeCredential(password, mode: modeCompMdp)

        // Step 4: Derive AES key
        let authKey = PronoteCrypto.deriveAuthKey(
            username: normalizedUsername,
            password: normalizedPassword,
            alea: alea
        )

        // Step 5: Solve challenge
        let solvedChallenge = try PronoteCrypto.solveChallenge(
            encrypted: challengeData,
            key: authKey,
            iv: aesIV
        )

        // Step 6: Authenticate
        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge.hexString,
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
        if let cleHex = authData["cle"] as? String, let cleData = Data(hexString: cleHex) {
            // Decrypt cle with auth key
            let decryptedCle = try PronoteCrypto.aesDecrypt(data: cleData, key: authKey, iv: aesIV)
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

        guard let challengeData = Data(hexString: challengeHex) else {
            throw PronoteError.encryptionFailed("Invalid challenge hex")
        }

        // For token login, the "password" in key derivation is the token
        let authKey = PronoteCrypto.deriveAuthKey(
            username: username,
            password: token,
            alea: alea
        )

        let solvedChallenge = try PronoteCrypto.solveChallenge(
            encrypted: challengeData,
            key: authKey,
            iv: aesIV
        )

        // Step 6: Authenticate
        let authPayload: [String: Any] = [
            "donnees": [
                "connexion": 0,
                "challenge": solvedChallenge.hexString,
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
}
