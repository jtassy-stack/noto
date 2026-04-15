import SwiftUI
import SwiftData

struct RootView: View {
    @Query private var families: [Family]
    @State private var showAddChild = false
    @Environment(\.modelContext) private var modelContext

    private var family: Family? { families.first }

    /// Re-establish ENT session on cold launch using stored Keychain credentials.
    /// Must run before preloadENTPhotos() so cookies are valid when fetching.
    private func reAuthENT() async {
        guard let family else { return }
        let entChildren = family.children.filter { $0.schoolType == .ent }
        guard !entChildren.isEmpty else { return }

        var providers = Set<ENTProvider>()
        for child in entChildren { providers.insert(child.entProvider ?? .pcn) }

        for provider in providers {
            let key = "ent_credentials_\(provider.rawValue)"
            guard let credsData = try? KeychainService.load(key: key),
                  let creds = String(data: credsData, encoding: .utf8) else { continue }
            let parts = creds.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let loginURL = provider.baseURL.appendingPathComponent("auth/login")
            do {
                let cookies = try await HeadlessENTAuth.login(
                    loginURL: loginURL,
                    email: String(parts[0]),
                    password: String(parts[1])
                )
                ENTClient.importCookies(cookies)
                NotificationCenter.default.post(name: .entSessionReady, object: nil)
                NSLog("[noto] RootView: ENT auto-auth OK for %@", provider.name)
            } catch {
                NSLog("[noto] RootView: ENT auto-auth failed for %@: %@", provider.name, error.localizedDescription)
            }
        }
    }

    /// Preload photos that are already in SwiftData but not yet in the disk cache.
    /// Uses whatever ENT session cookies are in memory — works on warm launch, no-ops on cold.
    private func preloadENTPhotos() async {
        guard let family else { return }
        let entChildren = family.children.filter { $0.schoolType == .ent }

        // Group by provider to share one ENTClient (and its URLSession) per provider
        var byProvider: [ENTProvider: [String]] = [:]
        for child in entChildren {
            let provider = child.entProvider ?? .pcn
            let paths = child.photos.map(\.entPath)
            byProvider[provider, default: []].append(contentsOf: paths)
        }

        for (provider, paths) in byProvider {
            guard !paths.isEmpty else { continue }
            let client = ENTClient(provider: provider)
            Task.detached(priority: .background) {
                await ENTPhotoCache.shared.preload(paths: paths, client: client)
            }
        }
    }

    var body: some View {
        Group {
            if families.isEmpty {
                OnboardingView()
            } else if family?.children.isEmpty == true {
                // Family exists but no children yet — prompt to add
                VStack(spacing: NotoTheme.Spacing.xl) {
                    Spacer()
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(NotoTheme.Colors.brand)
                    Text("Ajoutez votre premier enfant")
                        .font(NotoTheme.Typography.title)
                    Text("Connectez un compte Pronote ou ENT pour commencer.")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, NotoTheme.Spacing.xl)
                    Button {
                        showAddChild = true
                    } label: {
                        Text("Ajouter un enfant")
                            .font(NotoTheme.Typography.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, NotoTheme.Spacing.sm)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NotoTheme.Colors.brand)
                    .padding(.horizontal, NotoTheme.Spacing.xl)
                    Spacer()
                }
                .sheet(isPresented: $showAddChild) {
                    AddChildView()
                }
            } else {
                MainTabView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Attempt silent reconnect on every launch using stored refresh tokens.
            // Runs in background — UI is not blocked. HomeView observes
            // PronoteService.isConnected and fires an initial sync when the
            // bridge becomes available, so no notification is needed here.
            await PronoteAutoConnect.autoConnect(modelContext: modelContext)

            // Re-establish ENT session on cold launch (cookies don't survive app restart).
            // Must run before preloadENTPhotos so the session is valid when fetching.
            await reAuthENT()

            // Pre-warm ENT photo cache with the freshly established session.
            await preloadENTPhotos()
        }
    }
}
