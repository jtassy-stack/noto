import SwiftUI
import SwiftData
import AVFoundation
import PhotosUI
import CoreImage
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "PronoteQR")

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
    @State private var errorMessage: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showLiveCamera = false
    @State private var cameraPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

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
            case .success(let childName):
                successView(childName: childName)
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
                    requestCameraAndScan()
                } label: {
                    Label("Scanner avec la caméra", systemImage: "camera")
                        .font(NotoTheme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.pronote)
                .sheet(isPresented: $showLiveCamera) {
                    LiveCameraSheet(
                        onDetected: { payload in
                            showLiveCamera = false
                            handleQRPayload(payload)
                        },
                        onError: { message in
                            showLiveCamera = false
                            errorMessage = message
                        }
                    )
                }

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

    // MARK: - Success

    private func successView(childName: String) -> some View {
        VStack(spacing: NotoTheme.Spacing.xl) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(NotoTheme.Colors.success)

            Text("\(childName) connecté·e ✓")
                .font(NotoTheme.Typography.title)

            Text("Les données scolaires seront synchronisées automatiquement.")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.xl)

            Spacer()

            VStack(spacing: NotoTheme.Spacing.md) {
                Button {
                    step = .scan
                    pin = ""
                    qrData = nil
                    errorMessage = nil
                } label: {
                    Label("Ajouter un autre enfant", systemImage: "person.badge.plus")
                        .font(NotoTheme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                }
                .buttonStyle(.bordered)
                .tint(NotoTheme.Colors.pronote)

                Button {
                    dismissToHome()
                } label: {
                    Text("Terminer")
                        .font(NotoTheme.Typography.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.pronote)
            }
            .padding(.horizontal, NotoTheme.Spacing.xl)
            .padding(.bottom, NotoTheme.Spacing.xl)
        }
        // Auto-dismiss after 2s using .task so cancellation is automatic
        // if the user taps "Ajouter un autre enfant" (step changes, view disappears)
        .task {
            try? await Task.sleep(for: .seconds(2))
            guard case .success = step else { return }
            dismissToHome()
        }
    }

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

        let ciImage = CIImage(cgImage: cgImage)
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            errorMessage = "Impossible d'initialiser le détecteur QR."
            return
        }

        let qrFeatures = detector.features(in: ciImage).compactMap { $0 as? CIQRCodeFeature }
        guard let payload = qrFeatures.first?.messageString else {
            errorMessage = "Aucun QR code trouvé dans cette image. Assurez-vous que le QR code Pronote est bien visible."
            return
        }

        handleQRPayload(payload)
    }

    // MARK: - Auth

    private func authenticate() async {
        guard let qrData, pin.count == 4 else { return }

        step = .loading
        errorMessage = nil

        let deviceUUID = getOrCreateDeviceUUID()

        do {
            let bridge = try PawnoteBridge()

            let qrCopy: [String: String] = [
                "url": qrData["url"] as? String ?? "",
                "login": qrData["login"] as? String ?? "",
                "jeton": qrData["jeton"] as? String ?? "",
            ]
            let refreshToken = try await bridge.loginWithQRCode(
                deviceUUID: deviceUUID, pin: pin, qrData: qrCopy
            )

            // Persist refresh token — failure here means session will be lost on relaunch
            do {
                let tokenData = try JSONEncoder().encode(refreshToken)
                try KeychainService.save(key: "pronote_token_\(refreshToken.username)", data: tokenData)
                var knownUsernames = UserDefaults.standard.stringArray(forKey: "pronote_known_usernames") ?? []
                if !knownUsernames.contains(refreshToken.username) {
                    knownUsernames.append(refreshToken.username)
                    UserDefaults.standard.set(knownUsernames, forKey: "pronote_known_usernames")
                }
            } catch {
                logger.error("Keychain save failed for \(refreshToken.username): \(error)")
                errorMessage = "Connexion réussie mais impossible de sauvegarder vos identifiants. Réessayez."
                step = .scan
                return
            }

            let pronoteChildren = bridge.getChildren()

            guard let family else {
                logger.error("authenticate: no Family found in SwiftData")
                errorMessage = "Aucun profil famille trouvé. Relancez l'application."
                step = .scan
                return
            }

            var newlyInserted: [Child] = []
            for pc in pronoteChildren {
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
                newlyInserted.append(child)
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
                newlyInserted.append(child)
            }

            do {
                try modelContext.save()
            } catch {
                logger.error("SwiftData save failed: \(error)")
                errorMessage = "Impossible de sauvegarder le profil de votre enfant : \(error.localizedDescription)"
                step = .scan
                return
            }

            // Sync only children from THIS login session, using bridge-local indices.
            // Partial fetch failures (e.g. school blocks one endpoint) are non-fatal:
            // the child row and refresh token are already persisted; missing sections
            // will retry on the next sync cycle.
            let syncService = PronoteSyncService(modelContext: modelContext)
            for (index, child) in newlyInserted.enumerated() {
                await syncService.sync(child: child, bridge: bridge, childIndex: index)
                if !syncService.failedCategories.isEmpty {
                    logger.warning("Partial sync during onboarding for \(child.firstName, privacy: .private): missing \(syncService.failedCategories.joined(separator: ", "), privacy: .public)")
                }
            }

            PronoteService.shared.setBridge(bridge)

            let addedName = newlyInserted.last?.firstName ?? refreshToken.username
            step = .success(childName: addedName)
        } catch {
            let raw: String
            if case PronoteError.invalidResponse(let msg) = error {
                raw = msg.lowercased()
            } else {
                raw = error.localizedDescription.lowercased()
            }

            if raw.contains("page does not exist") || raw.contains("requested page") {
                errorMessage = "QR code expiré ou URL Pronote invalide. Régénérez le QR code dans Pronote et réessayez."
            } else if raw.contains("challenge") || raw.contains("credentials") || raw.contains("badcredentials") {
                errorMessage = "Code PIN incorrect. Vérifiez le code à 4 chiffres choisi dans Pronote et réessayez."
            } else if raw.contains("network") || raw.contains("timeout") || raw.contains("connexion") {
                errorMessage = "Impossible de joindre le serveur Pronote. Vérifiez votre connexion."
            } else {
                logger.error("Pronote QR auth failed: \(error.localizedDescription)")
                errorMessage = "Erreur de connexion. Régénérez le QR code dans Pronote et réessayez."
            }
            pin = ""
            step = .pin
        }
    }

    private func requestCameraAndScan() {
        switch cameraPermission {
        case .authorized:
            showLiveCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraPermission = granted ? .authorized : .denied
                    if granted { showLiveCamera = true }
                }
            }
        case .denied:
            errorMessage = "L'accès à la caméra a été refusé. Autorisez-le dans Réglages > Confidentialité > Caméra > nōto."
        case .restricted:
            errorMessage = "L'accès à la caméra est restreint sur cet appareil. Utilisez la galerie photos à la place."
        @unknown default:
            errorMessage = "Accès à la caméra non disponible."
        }
    }

    private func handleQRPayload(_ payload: String) {
        guard let jsonData = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            errorMessage = "QR code détecté mais format inattendu. Contenu : \(String(payload.prefix(100)))"
            return
        }
        qrData = parsed
        errorMessage = nil
        step = .pin
    }

    private func dismissToHome() {
        NotificationCenter.default.post(name: .navigateToHome, object: nil)
        dismiss()
    }

    private func getOrCreateDeviceUUID() -> String {
        if let data = try? KeychainService.load(key: "device_uuid"),
           let uuid = String(data: data, encoding: .utf8) {
            return uuid
        }
        let uuid = UUID().uuidString
        do {
            try KeychainService.save(key: "device_uuid", data: Data(uuid.utf8))
        } catch {
            logger.error("Failed to persist device UUID: \(error)")
        }
        return uuid
    }

    private func inferLevel(from className: String) -> SchoolLevel {
        let lower = className.lowercased()
        if lower.contains("6e") || lower.contains("5e") || lower.contains("4e") || lower.contains("3e") { return .college }
        if lower.contains("2nde") || lower.contains("1re") || lower.contains("1ere") || lower.contains("tle") { return .lycee }
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
    case success(childName: String)
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

// MARK: - Live Camera Sheet

private struct LiveCameraSheet: View {
    let onDetected: (String) -> Void
    let onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CameraQRScannerView(onDetected: onDetected, onError: { message in
                    dismiss()
                    onError(message)
                })
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Pointez la caméra vers le QR code Pronote")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(.bottom, NotoTheme.Spacing.xl)
                }
            }
            .navigationTitle("Scanner le QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .tint(.white)
                }
            }
        }
    }
}
