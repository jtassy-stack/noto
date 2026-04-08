import SwiftUI

/// Branded nōto. logo — Pixelify Sans Bold, 1-Up green accents on macron and dot.
struct NotoLogo: View {
    var size: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            Text("n")
                .font(NotoTheme.Typography.pixel(size))
                .foregroundStyle(NotoTheme.Colors.paper)
            // ō with green macron — use the character directly
            Text("ō")
                .font(NotoTheme.Typography.pixel(size))
                .foregroundStyle(NotoTheme.Colors.brand)
            Text("to")
                .font(NotoTheme.Typography.pixel(size))
                .foregroundStyle(NotoTheme.Colors.paper)
            Text(".")
                .font(NotoTheme.Typography.pixel(size))
                .foregroundStyle(NotoTheme.Colors.brand)
        }
    }
}
