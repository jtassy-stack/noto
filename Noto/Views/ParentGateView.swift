import SwiftUI

/// PIN entry, reused for both setting a new parent-gate code (onboarding,
/// child-mode devices) and verifying it (unlocking Settings from
/// `ChildHomeView`). Visual/accessibility pattern mirrors the Pronote QR
/// login's PIN step (`PronoteQRLoginView`).
struct ParentGateView: View {
    enum Mode {
        case verify
        case setUp
    }

    let mode: Mode
    /// `.verify`: called with `true`/`false` once 4 digits are entered.
    /// `.setUp`: called with `true` once the PIN has been saved.
    let onComplete: (Bool) -> Void
    /// Called when the parent taps "Annuler". Optional because the default
    /// (`@Environment(\.dismiss)`) only does something when this view is
    /// sheet-presented (ChildHomeView's `.verify` usage) — when it's shown
    /// inline as an onboarding step instead (`.setUp`), there is no
    /// presentation to dismiss and `dismiss()` silently no-ops, leaving a
    /// dead-end screen. Callers in that context must pass their own
    /// navigation-back action here.
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirmPin = ""
    @State private var awaitingConfirmation = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: NotoTheme.Spacing.xl) {
                Spacer()

                Image(systemName: "lock.shield")
                    .font(.system(size: 48))
                    .foregroundStyle(NotoTheme.Colors.brand)

                Text(title)
                    .font(NotoTheme.Typography.title)

                Text(subtitle)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NotoTheme.Spacing.xl)

                pinDigits

                TextField("", text: activeBinding)
                    .keyboardType(.numberPad)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .focused($fieldFocused)
                    .accessibilityLabel("Code parent")
                    .accessibilityValue("\(activeBinding.wrappedValue.count) chiffres sur 4 saisis")
                    .onChange(of: pin) { _, newValue in pin = filtered(newValue) }
                    .onChange(of: confirmPin) { _, newValue in confirmPin = filtered(newValue) }
                    .onChange(of: activeBinding.wrappedValue) { _, newValue in
                        guard newValue.count == 4 else { return }
                        handleFourDigits()
                    }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.danger)
                }

                Spacer()

                Text("Appuyez pour saisir le code")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(.bottom, NotoTheme.Spacing.xl)
            }
            .contentShape(Rectangle())
            .onTapGesture { fieldFocused = true }
            .onAppear { fieldFocused = true }
            .background(NotoTheme.Colors.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        if mode == .verify { onComplete(false) }
                        if let onCancel {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - State

    private var activeBinding: Binding<String> {
        mode == .setUp && awaitingConfirmation ? $confirmPin : $pin
    }

    private var title: String {
        switch mode {
        case .verify: return "Code parent"
        case .setUp: return awaitingConfirmation ? "Confirmez le code" : "Créez un code parent"
        }
    }

    private var subtitle: String {
        switch mode {
        case .verify:
            return "Entrez le code parent pour accéder aux réglages."
        case .setUp:
            return awaitingConfirmation
                ? "Saisissez-le une seconde fois pour confirmer."
                : "Ce code protège les réglages de contrôle parental — votre enfant ne doit pas le connaître."
        }
    }

    private var pinDigits: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            ForEach(0..<4, id: \.self) { index in
                let value = activeBinding.wrappedValue
                let digit = index < value.count ? String(value[value.index(value.startIndex, offsetBy: index)]) : ""
                Text(digit)
                    .font(NotoTheme.Typography.data)
                    .frame(width: 48, height: 56)
                    .background(NotoTheme.Colors.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                            .stroke(index == value.count ? NotoTheme.Colors.brand : Color.clear, lineWidth: 2)
                    )
            }
        }
        .padding(.vertical, NotoTheme.Spacing.md)
        .accessibilityHidden(true)
    }

    // MARK: - Logic

    private func filtered(_ raw: String) -> String {
        String(raw.filter(\.isNumber).prefix(4))
    }

    private func handleFourDigits() {
        switch mode {
        case .verify:
            let ok = ParentGateService.verify(pin)
            if ok {
                onComplete(true)
                dismiss()
            } else {
                errorMessage = "Code incorrect."
                pin = ""
            }

        case .setUp:
            if !awaitingConfirmation {
                errorMessage = nil
                awaitingConfirmation = true
            } else if confirmPin == pin {
                do {
                    try ParentGateService.setPIN(pin)
                    onComplete(true)
                    dismiss()
                } catch {
                    errorMessage = "Impossible d'enregistrer le code. Réessayez."
                    confirmPin = ""
                }
            } else {
                errorMessage = "Les codes ne correspondent pas — recommencez."
                pin = ""
                confirmPin = ""
                awaitingConfirmation = false
            }
        }
    }
}
