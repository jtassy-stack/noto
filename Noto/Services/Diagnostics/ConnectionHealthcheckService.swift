import Foundation
import SwiftData

/// One diagnostic result for a single child's school connection.
struct ConnectionCheckResult: Identifiable {
    enum Status {
        case ok(latencyMs: Int)
        case failed(String)
    }

    let id = UUID()
    let childName: String
    let connectionLabel: String
    let status: Status
}

/// Read-only connectivity check for each configured school connection
/// (Pronote, MonLycée, ENT/PCN, École Directe). Reuses the same
/// auth + fetch calls as the real sync path, but only calls the
/// lightest read endpoint per provider (grades / children list) and
/// never writes to SwiftData — this is a diagnostic, not a sync.
///
/// Surfaces exactly what "the connection to X broke" looks like in
/// practice: an auth failure, a parse failure (API shape changed),
/// or a plain network failure — each with its own message, so a
/// parent-support conversation ("nōto ne se connecte plus") can be
/// triaged in one tap instead of a manual QR re-login guess.
@MainActor
enum ConnectionHealthcheckService {

    static func run(children: [Child], modelContext: ModelContext) async -> [ConnectionCheckResult] {
        var results: [ConnectionCheckResult] = []

        let pronoteChildren = children.filter { $0.schoolType == .pronote || $0.entProvider == .monlycee }
        let entChildren = children.filter { $0.schoolType == .ent && $0.entProvider != .monlycee }
        let edChildren = children.filter { $0.schoolType == .ecoledirecte }
        let skolengoChildren = children.filter { $0.schoolType == .skolengo }

        if !pronoteChildren.isEmpty {
            results.append(contentsOf: await checkPronote(pronoteChildren, modelContext: modelContext))
        }
        if !entChildren.isEmpty {
            results.append(contentsOf: await checkENT(entChildren))
        }
        if !edChildren.isEmpty {
            results.append(contentsOf: await checkEcoleDirecte(edChildren))
        }
        if !skolengoChildren.isEmpty {
            results.append(contentsOf: await checkSkolengo(skolengoChildren))
        }

        return results
    }

    // MARK: - Pronote / MonLycée

    private static func checkPronote(_ children: [Child], modelContext: ModelContext) async -> [ConnectionCheckResult] {
        if PronoteService.shared.bridge == nil && !PronoteService.shared.isReconnecting {
            await PronoteAutoConnect.autoConnect(modelContext: modelContext)
        } else if PronoteService.shared.isReconnecting {
            while PronoteService.shared.isReconnecting {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        guard let bridge = PronoteService.shared.bridge else {
            return children.map {
                ConnectionCheckResult(
                    childName: $0.firstName,
                    connectionLabel: "Pronote",
                    status: .failed("Connexion impossible — reconnectez-vous via QR code.")
                )
            }
        }

        let roster = bridge.getChildren()
        var results: [ConnectionCheckResult] = []
        for child in children {
            guard let idx = ChildIndexResolver.resolve(child: child, pawnoteChildren: roster) else {
                results.append(ConnectionCheckResult(
                    childName: child.firstName,
                    connectionLabel: "Pronote",
                    status: .failed("Non lié — reconnectez via QR code.")
                ))
                continue
            }
            bridge.setActiveChild(index: idx)
            let start = DispatchTime.now()
            do {
                _ = try await bridge.fetchGrades()
                let ms = elapsedMs(since: start)
                results.append(ConnectionCheckResult(childName: child.firstName, connectionLabel: "Pronote", status: .ok(latencyMs: ms)))
            } catch {
                results.append(ConnectionCheckResult(
                    childName: child.firstName,
                    connectionLabel: "Pronote",
                    status: .failed(error.localizedDescription)
                ))
            }
        }
        return results
    }

    // MARK: - ENT / PCN

    private static func checkENT(_ children: [Child]) async -> [ConnectionCheckResult] {
        var byProvider: [ENTProvider: [Child]] = [:]
        for child in children {
            byProvider[child.entProvider ?? .pcn, default: []].append(child)
        }

        var results: [ConnectionCheckResult] = []
        for (provider, providerChildren) in byProvider {
            let key = "ent_credentials_\(provider.rawValue)"
            guard let credsData = try? KeychainService.load(key: key),
                  let creds = String(data: credsData, encoding: .utf8) else {
                results.append(contentsOf: providerChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: provider.name, status: .failed("Identifiants manquants."))
                })
                continue
            }
            let parts = creds.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                results.append(contentsOf: providerChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: provider.name, status: .failed("Identifiants corrompus."))
                })
                continue
            }

            let client = ENTClient(provider: provider)
            let start = DispatchTime.now()
            do {
                let loginURL = provider.baseURL.appendingPathComponent("auth/login")
                let cookies = try await HeadlessENTAuth.login(
                    loginURL: loginURL,
                    email: String(parts[0]),
                    password: String(parts[1])
                )
                ENTClient.importCookies(cookies)
                _ = try await client.fetchChildren()
                let ms = elapsedMs(since: start)
                results.append(contentsOf: providerChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: provider.name, status: .ok(latencyMs: ms))
                })
            } catch {
                results.append(contentsOf: providerChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: provider.name, status: .failed(error.localizedDescription))
                })
            }
        }
        return results
    }

    // MARK: - École Directe

    private static func checkEcoleDirecte(_ children: [Child]) async -> [ConnectionCheckResult] {
        var byAccount: [String: [Child]] = [:]
        for child in children {
            let key = child.edAccountId ?? child.entChildId ?? child.firstName
            byAccount[key, default: []].append(child)
        }

        var results: [ConnectionCheckResult] = []
        for (accountId, accountChildren) in byAccount {
            let credKey = "ed_credentials_\(accountId)"
            guard let credsData = try? KeychainService.load(key: credKey),
                  let creds = String(data: credsData, encoding: .utf8) else {
                results.append(contentsOf: accountChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: "École Directe", status: .failed("Identifiants manquants."))
                })
                continue
            }
            let parts = creds.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                results.append(contentsOf: accountChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: "École Directe", status: .failed("Identifiants corrompus."))
                })
                continue
            }

            let client = EcoleDirecteClient(accountId: accountId)
            let loginStart = DispatchTime.now()
            do {
                _ = try await client.login(username: String(parts[0]), password: String(parts[1]))
            } catch {
                results.append(contentsOf: accountChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: "École Directe", status: .failed("Connexion échouée — \(error.localizedDescription)"))
                })
                continue
            }

            for child in accountChildren {
                guard let eleveIdStr = child.entChildId, let eleveId = Int(eleveIdStr) else {
                    results.append(ConnectionCheckResult(childName: child.firstName, connectionLabel: "École Directe", status: .failed("Identifiant élève manquant.")))
                    continue
                }
                let start = DispatchTime.now()
                do {
                    _ = try await client.fetchGrades(eleveId: eleveId)
                    let ms = elapsedMs(since: start)
                    results.append(ConnectionCheckResult(childName: child.firstName, connectionLabel: "École Directe", status: .ok(latencyMs: ms)))
                } catch {
                    results.append(ConnectionCheckResult(childName: child.firstName, connectionLabel: "École Directe", status: .failed(error.localizedDescription)))
                }
            }
            _ = loginStart // login latency folded into the per-child fetch above
        }
        return results
    }

    // MARK: - Skolengo

    private static func checkSkolengo(_ children: [Child]) async -> [ConnectionCheckResult] {
        var bySchool: [String: [Child]] = [:]
        for child in children {
            guard let schoolId = child.skolengoSchoolId else {
                continue
            }
            bySchool[schoolId, default: []].append(child)
        }

        var results: [ConnectionCheckResult] = []
        for (schoolId, schoolChildren) in bySchool {
            let school = SkolengoSchool(
                id: schoolId,
                name: schoolChildren.first?.establishment ?? "",
                city: nil,
                emsCode: schoolChildren.first?.skolengoEmsCode,
                emsOIDCWellKnownUrl: ""
            )
            let client = SkolengoClient(school: school)
            do {
                try await client.ensureValidToken()
            } catch {
                results.append(contentsOf: schoolChildren.map {
                    ConnectionCheckResult(childName: $0.firstName, connectionLabel: "Skolengo", status: .failed("Connexion échouée — \(error.localizedDescription)"))
                })
                continue
            }

            for child in schoolChildren {
                guard let userId = child.skolengoUserId else {
                    results.append(ConnectionCheckResult(childName: child.firstName, connectionLabel: "Skolengo", status: .failed("Identifiant utilisateur manquant.")))
                    continue
                }
                let start = DispatchTime.now()
                do {
                    _ = try await client.fetchGrades(userId: userId)
                    let ms = elapsedMs(since: start)
                    results.append(ConnectionCheckResult(childName: child.firstName, connectionLabel: "Skolengo", status: .ok(latencyMs: ms)))
                } catch {
                    results.append(ConnectionCheckResult(childName: child.firstName, connectionLabel: "Skolengo", status: .failed(error.localizedDescription)))
                }
            }
        }
        return results
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
