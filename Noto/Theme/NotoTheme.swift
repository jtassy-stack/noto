import SwiftUI

enum NotoTheme {
    // MARK: - Colors
    // Source: Notion — nōto. Moodboard & Design System
    // Dark-mode-first. Retro/anime 90s aesthetic.
    // All semantic colors adapt automatically to light/dark mode.
    enum Colors {
        // MARK: Core palette — fixed (design system Notion)
        // Source: nōto. Brief Design — https://www.notion.so/331e0fdcdce88120b109ff193b9d808d

        static let brand   = Color(hex: 0x5BD45B)   // 1-Up green — accent signature
        static let indigo  = Color(hex: 0x2B2B6E)   // Super Famicom surface
        static let dmg     = Color(hex: 0x9BBB0F)   // Game Boy green (vigilance)
        static let crimson = Color(hex: 0xDC2626)   // rouge froid alertes
        static let cherry  = Color(hex: 0xBE123C)   // rouge profond hover/active
        static let cobalt  = Color(hex: 0x2563EB)   // liens, interactif
        static let sky     = Color(hex: 0x38BDF8)   // liens hover
        static let amber   = Color(hex: 0xCA8A04)   // avertissements (jaune/doré PAS orange)
        static let forest  = Color(hex: 0x0F380F)   // Game Boy easter egg
        static let mist    = Color(hex: 0xB0B0D0)   // texte secondaire sombre, bordures

        // MARK: Adaptive semantic colors (dark-mode-first)

        /// Page background — Paper #F5F3EE / Shadow #0A0A08
        static let background = adaptive(dark: 0x0A0A08, light: 0xF5F3EE)

        /// Card / elevated surface — Charbon #222222 / blanc chaud #FDFCF9
        static let surface = adaptive(dark: 0x222222, light: 0xFDFCF9)

        /// Slightly elevated surface — SFC indigo / Paper teinté
        static let surfaceElevated = adaptive(dark: 0x1A1A2E, light: 0xEDEBE4)

        /// Deep accent surface — Indigo SFC / Paper foncé
        static let surfaceSecondary = adaptive(dark: 0x2B2B6E, light: 0xE2E0D8)

        /// Subtle border
        static let border = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.10)
                : UIColor.black.withAlphaComponent(0.12)
        })

        /// Primary text — Paper #F5F3EE / Shadow #0A0A08
        static let textPrimary = adaptive(dark: 0xF5F3EE, light: 0x0A0A08)

        /// Secondary text — Mist #B0B0D0 / Graphite #555555
        static let textSecondary = adaptive(dark: 0xB0B0D0, light: 0x555555)

        /// Tertiary / disabled — Graphite #555555 / gris moyen #888888
        static let textTertiary = adaptive(dark: 0x555555, light: 0x888888)

        /// Foreground on brand surface (button text etc.) — Shadow / Paper
        static let shadow = adaptive(dark: 0x0A0A08, light: 0x0A0A08)

        /// Paper-like tone — Paper / Shadow
        static let paper = adaptive(dark: 0xF5F3EE, light: 0x0A0A08)

        // MARK: Semantic aliases
        static let card    = surface
        static let success = brand
        static let warning = amber
        static let danger  = crimson

        // MARK: Service colors (fixed)
        static let pronote = Color(hex: 0x8B46E6)
        static let ent     = cobalt

        // MARK: - Helper
        private static func adaptive(dark: UInt, light: UInt) -> Color {
            Color(UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(hex: dark)
                    : UIColor(hex: light)
            })
        }
    }

    // MARK: - Typography
    // Space Mono (body, data) + Instrument Serif (accents) + Pixelify Sans (logo)
    enum Typography {
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom(weight == .bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size)
        }

        static func serif(_ size: CGFloat, italic: Bool = true) -> Font {
            .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
        }

        static func pixel(_ size: CGFloat) -> Font {
            .custom("PixelifySans-Bold", size: size)
        }

        static let largeTitle = mono(24, weight: .bold)
        static let title      = mono(20, weight: .bold)
        static let headline   = mono(16, weight: .bold)
        static let body       = mono(14)
        static let caption    = mono(12)
        static let data       = mono(16, weight: .bold)
        static let dataLarge  = mono(36, weight: .bold)
        static let dataSmall  = mono(11)
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
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

extension UIColor {
    convenience init(hex: UInt, alpha: CGFloat = 1) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - View Modifiers

extension View {
    /// Standard nōto card style — adaptive surface with subtle border.
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
