import SwiftUI

/// Progress indicator for multi-step onboarding.
///
/// Shows a pill for the active step (wider, brand color) and dots for
/// other steps — green for completed, border color for upcoming.
///
/// Visual grammar:
///   - color = state (brand=current, success=done, border=upcoming)
///   - spacing = 8pt between pills
struct StepIndicator: View {
    /// 0-indexed current step.
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
            ForEach(0..<totalSteps, id: \.self) { idx in
                if idx == currentStep {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(NotoTheme.Colors.brand)
                        .frame(width: 24, height: 6)
                } else {
                    Circle()
                        .fill(idx < currentStep
                              ? NotoTheme.Colors.success
                              : NotoTheme.Colors.border)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Étape \(currentStep + 1) sur \(totalSteps)")
    }
}

#Preview {
    VStack(spacing: NotoTheme.Spacing.lg) {
        StepIndicator(currentStep: 0, totalSteps: 3)
        StepIndicator(currentStep: 1, totalSteps: 3)
        StepIndicator(currentStep: 2, totalSteps: 3)
    }
    .padding()
    .background(NotoTheme.Colors.background)
}
