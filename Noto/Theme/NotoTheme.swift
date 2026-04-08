import SwiftUI

enum NotoTheme {
    // MARK: - Colors
    // Source: Notion — nōto. Moodboard & Design System
    // Dark-mode-first. Retro/anime 90s aesthetic.
    enum Colors {
        // Core palette
        static let shadow = Color(hex: 0x0A0A08)           // fond principal (dark)
        static let paper = Color(hex: 0xF5F3EE)            // fond clair, texte sur sombre
        static let brand = Color(hex: 0x5BD45B)             // 1-Up green — accent principal

        // Secondary
        static let indigo = Color(hex: 0x2B2B6E)           // Super Famicom, surfaces secondaires sombres
        static let dmg = Color(hex: 0x9BBB0F)              // Game Boy green, état vigilance
        static let mist = Color(hex: 0xB0B0D0)             // texte secondaire sur sombre, bordures
        static let graphite = Color(hex: 0x555555)          // texte tertiaire, éléments désactivés

        // Semantic
        static let crimson = Color(hex: 0xDC2626)           // alertes, danger (rouge pur, JAMAIS orange)
        static let cobalt = Color(hex: 0x2563EB)            // liens, interactif, info
        static let amber = Color(hex: 0xD4A017)             // avertissements
        static let forest = Color(hex: 0x0F380F)            // Game Boy easter egg

        // Semantic aliases (used by existing views)
        static let background = shadow
        static let surface = shadow                          // cards on dark bg use slightly lighter
        static let surfaceSecondary = indigo
        static let card = Color(hex: 0x141414)              // card bg — slightly lifted from shadow
        static let border = Color.white.opacity(0.1)
        static let textPrimary = paper
        static let textSecondary = mist
        static let textTertiary = graphite
        static let success = brand
        static let warning = amber
        static let danger = crimson

        // Service colors
        static let pronote = Color(hex: 0x8b46e6)
        static let ent = cobalt
    }

    // MARK: - Typography
    // Space Mono (body, data) + Instrument Serif (accents) + Pixelify Sans (logo)
    enum Typography {
        /// Space Mono — body text, data, UI (retro monospace)
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom(weight == .bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size)
        }

        /// Instrument Serif — taglines, accents, elegance
        static func serif(_ size: CGFloat, italic: Bool = true) -> Font {
            .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
        }

        /// Pixelify Sans — logo only
        static func pixel(_ size: CGFloat) -> Font {
            .custom("PixelifySans-Bold", size: size)
        }

        // Semantic type scale — all Space Mono
        static let largeTitle   = mono(24, weight: .bold)
        static let title        = mono(20, weight: .bold)
        static let headline     = mono(16, weight: .bold)
        static let body         = mono(14)
        static let caption      = mono(12)
        static let data         = mono(16, weight: .bold)       // grade numbers
        static let dataLarge    = mono(36, weight: .bold)       // big stat cards
        static let dataSmall    = mono(11)
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
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let pill: CGFloat = 20
        static let card: CGFloat = 10
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

// MARK: - View Modifiers

extension View {
    /// Standard nōto card style — dark surface with subtle border
    func notoCard() -> some View {
        self
            .background(NotoTheme.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: NotoTheme.Radius.card)
                    .stroke(NotoTheme.Colors.border, lineWidth: 0.5)
            )
    }
}
