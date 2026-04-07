import SwiftUI
import SwiftData
import AVFoundation

/// Pronote QR Code login flow:
/// 1. Scan QR from Pronote app (contains JSON with server URL + token)
/// 2. Enter 4-digit PIN
/// 3. Authenticate → add children
struct PronoteQRLoginView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var step: QRStep = .scan
    @State private var qrData: [String: Any]?
    @State private var pin = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var family: Family? { families.first }

    var body: some View {
        VStack {
            switch step {
            case .scan:
                scanView
            case .pin:
                pinView
            case .loading:
                loadingView
            }
        }
        .navigationTitle("QR Code Pronote")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Scan Step

    private var scanView: some View {
        VStack(spacing: NotoTheme.Spacing.xl) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(NotoTheme.Colors.pronote)

            Text("Scannez le QR code")
                .font(NotoTheme.Typography.title)

            Text("Dans l'app Pronote de votre enfant :\nMenu → QR Code → Configurer un appareil mobile")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.xl)

            Spacer()

            VStack(spacing: NotoTheme.Spacing.md) {
                Button {
                    step = .scan
                    // Open camera — use QRScannerView
                } label: {
                    Label("Scanner avec la caméra", systemImage: "camera")
                        .font(NotoTheme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.pronote)

                // For simulator testing: paste JSON
                #if DEBUG
                Button {
                    // Fake QR data for testing
                    qrData = [
                        "url": "https://demo.index-education.net/pronote",
                        "jeton": "test-token-123",
                        "login": "demo-parent",
                    ]
                    step = .pin
                } label: {
                    Text("Mode démo (simulateur)")
                        .font(NotoTheme.Typography.caption)
                }
                .tint(NotoTheme.Colors.textSecondary)
                #endif
            }
            .padding(.horizontal, NotoTheme.Spacing.xl)
            .padding(.bottom, NotoTheme.Spacing.xl)
        }
    }

    // MARK: - PIN Step

    private var pinView: some View {
        VStack(spacing: NotoTheme.Spacing.xl) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(NotoTheme.Colors.pronote)

            Text("Code PIN")
                .font(NotoTheme.Typography.title)

            Text("Entrez le code PIN à 4 chiffres que vous avez choisi dans Pronote.")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.xl)

            // PIN dots display
            HStack(spacing: NotoTheme.Spacing.md) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? NotoTheme.Colors.pronote : NotoTheme.Colors.textSecondary.opacity(0.3))
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.vertical, NotoTheme.Spacing.md)

            // Hidden text field for PIN input
            TextField("", text: $pin)
                .keyboardType(.numberPad)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($pinFieldFocused)
                .onChange(of: pin) { _, newValue in
                    // Limit to 4 digits
                    if newValue.count > 4 {
                        pin = String(newValue.prefix(4))
                    }
                    // Auto-submit on 4 digits
                    if newValue.count == 4 {
                        Task { await authenticate() }
                    }
                }

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.danger)
            }

            Spacer()

            // Tap anywhere on the PIN area to focus
            Text("Appuyez pour saisir le code")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .padding(.bottom, NotoTheme.Spacing.xl)
        }
        .contentShape(Rectangle())
        .onTapGesture { pinFieldFocused = true }
        .onAppear { pinFieldFocused = true }
    }

    @FocusState private var pinFieldFocused: Bool

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: NotoTheme.Spacing.xl) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Connexion en cours…")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            Spacer()
        }
    }

    // MARK: - Auth

    private func authenticate() async {
        guard let qrData, pin.count == 4 else { return }

        step = .loading
        isLoading = true
        errorMessage = nil

        let deviceUUID = getOrCreateDeviceUUID()

        // Extract URL from QR data
        let serverURL = qrData["url"] as? String ?? ""
        let client = PronoteClient(url: serverURL, deviceUUID: deviceUUID)

        do {
            // QR login uses the token from QR + PIN as password
            let qrToken = qrData["jeton"] as? String ?? ""
            let qrLogin = qrData["login"] as? String ?? ""

            let refreshToken = try await client.login(
                username: qrLogin,
                password: pin + qrToken  // PIN prepended to QR token
            )

            // Store refresh token
            if let tokenData = try? JSONEncoder().encode(refreshToken) {
                try? KeychainService.save(key: "pronote_token_\(qrLogin)", data: tokenData)
            }

            // Get children
            let children = await client.children

            guard let family else { return }

            for pc in children {
                let child = Child(
                    firstName: pc.name.components(separatedBy: " ").first ?? pc.name,
                    level: inferLevel(from: pc.className),
                    grade: inferGrade(from: pc.className),
                    schoolType: .pronote,
                    establishment: pc.establishment
                )
                child.family = family
                modelContext.insert(child)
            }

            if children.isEmpty {
                // Fallback: create child from QR login name
                let child = Child(
                    firstName: qrLogin,
                    level: .college,
                    grade: "?",
                    schoolType: .pronote,
                    establishment: serverURL
                )
                child.family = family
                modelContext.insert(child)
            }

            try? modelContext.save()
            dismiss()
        } catch {
            errorMessage = "Code PIN incorrect ou QR code expiré."
            pin = ""
            step = .pin
        }

        isLoading = false
    }

    private func getOrCreateDeviceUUID() -> String {
        if let data = try? KeychainService.load(key: "device_uuid"),
           let uuid = String(data: data, encoding: .utf8) {
            return uuid
        }
        let uuid = UUID().uuidString
        try? KeychainService.save(key: "device_uuid", data: Data(uuid.utf8))
        return uuid
    }

    private func inferLevel(from className: String) -> SchoolLevel {
        let lower = className.lowercased()
        if lower.contains("6") || lower.contains("5") || lower.contains("4") || lower.contains("3") { return .college }
        if lower.contains("2nde") || lower.contains("1") || lower.contains("tle") { return .lycee }
        return .college
    }

    private func inferGrade(from className: String) -> String {
        let patterns = ["6e", "5e", "4e", "3e", "2nde", "1re", "Tle"]
        for p in patterns where className.lowercased().contains(p.lowercased()) { return p }
        return className.prefix(3).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Step

private enum QRStep {
    case scan
    case pin
    case loading
}
