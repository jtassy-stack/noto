import SwiftUI

enum NotoTheme {
    // MARK: - Colors
    enum Colors {
        static let brand = Color(red: 0.31, green: 0.44, blue: 0.95)   // indigo/blue accent
        static let surface = Color(.systemBackground)
        static let card = Color(.systemBackground)
        static let surfaceSecondary = Color(.secondarySystemBackground)
        static let textPrimary = Color(.label)
        static let textSecondary = Color(.secondaryLabel)
        static let danger = Color(red: 0.90, green: 0.22, blue: 0.21)
        static let warning = Color(red: 1.00, green: 0.60, blue: 0.10)
        static let success = Color(red: 0.20, green: 0.70, blue: 0.40)

        // Semantic
        static let pronote = Color(red: 0.55, green: 0.27, blue: 0.90) // purple Pronote
        static let ent = Color(red: 0.08, green: 0.40, blue: 0.75)     // bleu ENT
    }

    // MARK: - Typography
    enum Typography {
        static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        static let largeTitle = display(28, weight: .bold)
        static let title = display(22, weight: .semibold)
        static let headline = display(17, weight: .semibold)
        static let body = display(15, weight: .regular)
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
