import SwiftUI

enum NotoTheme {
    // MARK: - Colors
    enum Colors {
        static let brand = Color(hex: 0x4CAF50)        // 1-Up green accent
        static let surface = Color(.systemBackground)
        static let surfaceSecondary = Color(.secondarySystemBackground)
        static let textPrimary = Color(.label)
        static let textSecondary = Color(.secondaryLabel)
        static let danger = Color(hex: 0xE53935)
        static let warning = Color(hex: 0xFFA726)
        static let success = Color(hex: 0x43A047)

        // Semantic
        static let pronote = Color(hex: 0x2E7D32)   // vert Pronote
        static let ent = Color(hex: 0x1565C0)        // bleu ENT
    }

    // MARK: - Typography
    enum Typography {
        static let displayFont = "Inter"
        static let monoFont = "SpaceMono-Regular"

        static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom(displayFont, size: size).weight(weight)
        }

        static func mono(_ size: CGFloat) -> Font {
            .custom(monoFont, size: size)
        }

        static let largeTitle = display(28, weight: .bold)
        static let title = display(22, weight: .semibold)
        static let headline = display(17, weight: .semibold)
        static let body = display(15)
        static let caption = display(13, weight: .medium)
        static let data = mono(15)
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - Radius
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let card: CGFloat = 16
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
