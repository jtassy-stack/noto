import SwiftUI
import SwiftData
import AVFoundation
import PhotosUI
import CoreImage

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
    @State private var selectedPhoto: PhotosPickerItem?

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

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.danger)
                    .padding(.horizontal, NotoTheme.Spacing.xl)
            }

            VStack(spacing: NotoTheme.Spacing.md) {
                Button {
                    // TODO: Open live camera scanner (requires real device)
                } label: {
                    Label("Scanner avec la caméra", systemImage: "camera")
                        .font(NotoTheme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.pronote)

                PhotosPicker(
                    selection: $selectedPhoto,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Choisir depuis la galerie", systemImage: "photo.on.rectangle")
                        .font(NotoTheme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                }
                .buttonStyle(.bordered)
                .tint(NotoTheme.Colors.pronote)
                .onChange(of: selectedPhoto) { _, newItem in
                    Task { await processSelectedPhoto(newItem) }
                }
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

            // PIN digit display
            HStack(spacing: NotoTheme.Spacing.md) {
                ForEach(0..<4, id: \.self) { index in
                    let digit = index < pin.count ? String(pin[pin.index(pin.startIndex, offsetBy: index)]) : ""
                    Text(digit)
                        .font(NotoTheme.Typography.data)
                        .frame(width: 48, height: 56)
                        .background(NotoTheme.Colors.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                                .stroke(index == pin.count ? NotoTheme.Colors.pronote : Color.clear, lineWidth: 2)
                        )
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
                    let filtered = String(newValue.filter(\.isNumber).prefix(4))
                    if filtered != newValue { pin = filtered }
                    if filtered.count == 4 {
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

    // MARK: - Photo QR Detection

    private func processSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        errorMessage = nil

        // Load image data from PhotosPicker
        let cgImage: CGImage
        do {
            guard let data = try await item.loadTransferable(type: PhotoQRImage.self) else {
                errorMessage = "Impossible de charger l'image."
                return
            }
            cgImage = data.cgImage
        } catch {
            errorMessage = "Erreur de chargement : \(error.localizedDescription)"
            return
        }

        // Use CIDetector (works on simulator, no Neural Engine needed)
        let ciImage = CIImage(cgImage: cgImage)
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            errorMessage = "Impossible d'initialiser le détecteur QR."
            return
        }

        let features = detector.features(in: ciImage)
        let qrFeatures = features.compactMap { $0 as? CIQRCodeFeature }

        guard let payload = qrFeatures.first?.messageString else {
            errorMessage = "Aucun QR code trouvé dans cette image. Assurez-vous que le QR code Pronote est bien visible."
            return
        }

        print("[noto] QR payload: \(payload)")

        // Parse JSON from QR payload
        guard let jsonData = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            errorMessage = "QR code détecté mais format inattendu. Contenu : \(String(payload.prefix(100)))"
            return
        }

        qrData = parsed
        errorMessage = nil
        step = .pin
    }

    // MARK: - Auth

    private func authenticate() async {
        guard let qrData, pin.count == 4 else { return }

        step = .loading
        isLoading = true
        errorMessage = nil

        let deviceUUID = getOrCreateDeviceUUID()

        do {
            // Use PawnoteBridge (pawnote via JavaScriptCore) for reliable Pronote protocol
            let bridge = try PawnoteBridge()

            let qrCopy: [String: String] = [
                "url": qrData["url"] as? String ?? "",
                "login": qrData["login"] as? String ?? "",
                "jeton": qrData["jeton"] as? String ?? "",
            ]
            let refreshToken = try await bridge.loginWithQRCode(
                deviceUUID: deviceUUID, pin: pin, qrData: qrCopy
            )

            // Store refresh token
            if let tokenData = try? JSONEncoder().encode(refreshToken) {
                try? KeychainService.save(key: "pronote_token_\(refreshToken.username)", data: tokenData)
            }

            // Get children from pawnote session
            let pronoteChildren = bridge.getChildren()

            guard let family else { return }

            for (index, pc) in pronoteChildren.enumerated() {
                let nameParts = pc.name.split(separator: " ")
                let firstName = nameParts.count > 1
                    ? String(nameParts.dropFirst().joined(separator: " "))
                    : pc.name

                let child = Child(
                    firstName: firstName,
                    level: inferLevel(from: pc.className),
                    grade: inferGrade(from: pc.className),
                    schoolType: .pronote,
                    establishment: refreshToken.url
                )
                child.family = family
                modelContext.insert(child)
            }

            if pronoteChildren.isEmpty {
                let child = Child(
                    firstName: refreshToken.username,
                    level: .college,
                    grade: "?",
                    schoolType: .pronote,
                    establishment: refreshToken.url
                )
                child.family = family
                modelContext.insert(child)
            }

            try? modelContext.save()

            // Sync school data with the authenticated bridge session
            let syncService = PronoteSyncService(modelContext: modelContext)
            for (index, child) in family.children.enumerated() where child.schoolType == .pronote {
                await syncService.sync(child: child, bridge: bridge, childIndex: index)
            }

            if let syncError = syncService.lastSyncError {
                errorMessage = "Sync: \(syncError)"
                step = .pin
            } else {
                dismiss()
            }
        } catch {
            errorMessage = "Erreur : \(error)"
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

// MARK: - PhotosPicker Transferable

// MARK: - PIN to AES Key

extension Data {
    /// Pad PIN bytes (4 bytes) to a valid AES key size (16 bytes) with zeros.
    /// Matches node-forge createBuffer behavior.
    func pinPaddedToAESKey() -> Data {
        var padded = Data(count: 16)
        let copyCount = Swift.min(self.count, 16)
        padded.replaceSubrange(0..<copyCount, with: self.prefix(copyCount))
        return padded
    }
}

// MARK: - PhotosPicker Transferable

struct PhotoQRImage: Transferable {
    let cgImage: CGImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let uiImage = UIImage(data: data), let cg = uiImage.cgImage else {
                throw TransferError.importFailed
            }
            return PhotoQRImage(cgImage: cg)
        }
    }

    enum TransferError: Error {
        case importFailed
    }
}
