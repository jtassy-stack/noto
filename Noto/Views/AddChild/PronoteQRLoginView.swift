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
    /// Set synchronously inside the PIN `onChange` before spawning the auth
    /// Task, so two rapid onChange fires can't both queue an authenticate().
    @State private var isAuthenticating = false

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
            case .success(let childName, let partialSyncNote):
                successView(childName: childName, partialSyncNote: partialSyncNote)
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

                // The establishment's ENT (MonLycée, PCN…) holds the parent's
                // Pronote access: Pronote's own page does the CAS round trip
                // and hands out the same mobile token as the QR code.
                NavigationLink {
                    PronoteWebLoginView()
                } label: {
                    Text("Pas de QR code ? Se connecter par l'ENT de l'établissement")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, NotoTheme.Spacing.xs)
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
            .accessibilityHidden(true)

            // Hidden text field for PIN input
            TextField("", text: $pin)
                .keyboardType(.numberPad)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($pinFieldFocused)
                .accessibilityLabel("Code PIN")
                .accessibilityValue("\(pin.count) chiffres sur 4 saisis")
                .onChange(of: pin) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(4))
                    if filtered != newValue { pin = filtered }
                    // Guard against concurrent authenticate() calls: the flag
                    // is flipped synchronously before the Task is scheduled so
                    // two rapid fires (fast typing, failure reset) can't both
                    // pass the check. Reset in authenticate() when it returns.
                    if filtered.count == 4, !isAuthenticating, case .pin = step {
                        isAuthenticating = true
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

    private func successView(childName: String, partialSyncNote: String? = nil) -> some View {
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

            if let note = partialSyncNote {
                Label(note, systemImage: "info.circle")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.warning)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NotoTheme.Spacing.xl)
            }

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
        // The onChange guard already flipped isAuthenticating; this defer
        // makes sure every exit path (success, thrown error, SwiftData save
        // failure, Keychain failure) resets it so the user can retry.
        defer { isAuthenticating = false }

        step = .loading
        errorMessage = nil

        let deviceUUID = PronoteAccountStore.deviceUUID()

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
                try PronoteAccountStore.save(refreshToken)
            } catch {
                logger.error("Keychain save failed for \(refreshToken.username): \(error)")
                errorMessage = "Connexion réussie mais impossible de sauvegarder vos identifiants. Réessayez."
                step = .scan
                return
            }

            guard let family else {
                logger.error("authenticate: no Family found in SwiftData")
                errorMessage = "Aucun profil famille trouvé. Relancez l'application."
                step = .scan
                return
            }

            // Re-login from the same parent must NOT insert a new Child row
            // for kids we already track: the importer dedupes through
            // ChildDedupe (pawnoteID, then a composite fallback).
            let resolved: [Child]
            do {
                resolved = try PronoteChildImporter.importChildren(
                    from: bridge, token: refreshToken, family: family, modelContext: modelContext
                )
            } catch {
                logger.error("SwiftData save failed: \(error)")
                errorMessage = "Impossible de sauvegarder le profil de votre enfant : \(error.localizedDescription)"
                step = .scan
                return
            }

            let hadPartialFailure = await PronoteChildImporter.initialSync(
                children: resolved, bridge: bridge, modelContext: modelContext
            )

            PronoteService.shared.setBridge(bridge, for: refreshToken.username)

            let addedName = resolved.last?.firstName ?? refreshToken.username
            let note: String? = hadPartialFailure
                ? "Certaines données seront disponibles après la prochaine synchronisation."
                : nil
            step = .success(childName: addedName, partialSyncNote: note)
        } catch {
            let raw: String
            if case PronoteError.invalidResponse(let msg) = error {
                raw = msg.lowercased()
            } else {
                raw = error.localizedDescription.lowercased()
            }

            if case PronoteError.doubleAuthRequired(let info) = error {
                if let rescued = info?.rescuedToken {
                    // Keep the renewed token: once the parent has set up the
                    // double authentication in Pronote, « Réessayer » on the
                    // Accueil reopens the session without another scan.
                    try? PronoteAccountStore.save(rescued)
                }
                errorMessage = error.localizedDescription
            } else if raw.contains("page does not exist") || raw.contains("requested page") {
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


}

// MARK: - Step

private enum QRStep {
    case scan
    case pin
    case loading
    case success(childName: String, partialSyncNote: String? = nil)
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
