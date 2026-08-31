import SwiftUI
import SwiftData
import AuthenticationServices

/// Two-step Skolengo connection flow: search for the child's school
/// (Skolengo covers Occitanie, Auvergne-Rhône-Alpes, Bourgogne-Franche-Comté,
/// Grand Est, Corse, Savoie, Haute-Savoie, Loire, Isère — one shared API,
/// no per-region config needed), then complete an OIDC login for that
/// school via `ASWebAuthenticationSession`.
struct SkolengoLoginView: View {
    var onDismissAll: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var searchText = ""
    @State private var searchResults: [SkolengoSchool] = []
    @State private var isSearching = false
    @State private var selectedSchool: SkolengoSchool?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var webAuthSession: WebAuthSessionRunner?

    private var family: Family? { families.first }

    var body: some View {
        Form {
            Section {
                TextField("Nom de l'établissement", text: $searchText)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _, newValue in
                        Task { await search(newValue) }
                    }
            } header: {
                Text("Rechercher l'établissement")
            } footer: {
                Text("Skolengo couvre notamment Occitanie, Auvergne-Rhône-Alpes, Bourgogne-Franche-Comté, Grand Est, Corse, Savoie, Haute-Savoie, Loire et Isère.")
                    .font(NotoTheme.Typography.caption)
            }

            if isSearching {
                Section { ProgressView() }
            } else if !searchResults.isEmpty {
                Section {
                    ForEach(searchResults, id: \.id) { school in
                        Button {
                            Task { await beginLogin(school: school) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(school.name)
                                    .font(NotoTheme.Typography.body)
                                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                                if let city = school.city {
                                    Text(city)
                                        .font(NotoTheme.Typography.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                            }
                        }
                        .disabled(isLoading)
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(NotoTheme.Colors.danger)
                }
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Skolengo")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - School search

    private func search(_ text: String) async {
        guard text.count >= 2 else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await SkolengoClient.searchSchools(text: text)
        } catch {
            // Non-fatal — an empty result list reads as "no match" to the parent,
            // which is an acceptable fallback for a background search failure.
            NSLog("[noto][warn] Skolengo school search failed: \(error.localizedDescription)")
            searchResults = []
        }
    }

    // MARK: - Login

    @MainActor
    private func beginLogin(school: SkolengoSchool) async {
        errorMessage = nil
        isLoading = true
        selectedSchool = school

        let client = SkolengoClient(school: school)
        do {
            let authURL = try await client.buildAuthorizationURL()
            let runner = WebAuthSessionRunner()
            webAuthSession = runner
            let callbackURL = try await runner.start(url: authURL, callbackScheme: "skoapp-prod")
            let userId = try await client.completeLogin(callbackURL: callbackURL)
            try await createChildren(school: school, client: client, primaryUserId: userId)
            if let onDismissAll { onDismissAll() } else { dismiss() }
        } catch SkolengoError.authCancelled {
            errorMessage = nil // user-initiated cancel — no error banner needed
        } catch SkolengoError.badCredentials {
            errorMessage = "Identifiants Skolengo incorrects."
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    private func createChildren(school: SkolengoSchool, client: SkolengoClient, primaryUserId: String) async throws {
        guard let family else {
            errorMessage = "Aucune famille configurée. Relancez l'application."
            return
        }

        let linkedUsers = try await client.fetchLinkedUsers(userId: primaryUserId)
        guard !linkedUsers.isEmpty else {
            errorMessage = "Aucun élève trouvé sur ce compte."
            return
        }

        var createdAny = false
        for user in linkedUsers {
            let alreadyExists = family.children.contains {
                $0.schoolType == .skolengo && $0.skolengoUserId == user.id
            }
            guard !alreadyExists else { continue }

            let child = Child(
                firstName: user.firstName,
                level: inferLevel(from: user.className ?? ""),
                grade: user.className ?? "",
                schoolType: .skolengo,
                establishment: school.name
            )
            child.skolengoSchoolId = school.id
            child.skolengoEmsCode = school.emsCode
            child.skolengoUserId = user.id
            child.family = family
            modelContext.insert(child)
            createdAny = true
        }
        guard createdAny else { return }
        try modelContext.save()

        // Immediate sync (non-fatal: children are saved even if sync fails)
        let syncService = SkolengoSyncService(modelContext: modelContext)
        for child in family.children where child.schoolType == .skolengo && child.skolengoSchoolId == school.id {
            do {
                try await syncService.sync(child: child, client: client)
            } catch {
                NSLog("[noto][warn] Skolengo initial sync for %@: %@", child.firstName, error.localizedDescription)
            }
        }
    }

    private func inferLevel(from label: String) -> SchoolLevel {
        let lower = label.lowercased()
        if lower.contains("ps") || lower.contains("ms") || lower.contains("gs") { return .maternelle }
        if lower.contains("cp") || lower.contains("ce") || lower.contains("cm") { return .elementaire }
        if lower.contains("6") || lower.contains("5") || lower.contains("4") || lower.contains("3") { return .college }
        if lower.contains("2nd") || lower.contains("1") || lower.contains("tle") || lower.contains("ter") { return .lycee }
        return .college
    }
}

// MARK: - ASWebAuthenticationSession wrapper

/// Minimal async wrapper around `ASWebAuthenticationSession` — captures
/// the custom-scheme OAuth redirect (`skoapp-prod://sign-in-callback`)
/// without needing to register that scheme in nōto's own Info.plist;
/// the session claims it only for the duration of the auth flow.
@MainActor
private final class WebAuthSessionRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SkolengoError.authCancelled)
                } else {
                    continuation.resume(throwing: error ?? SkolengoError.authCancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
