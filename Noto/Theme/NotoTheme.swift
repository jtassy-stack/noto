import SwiftUI

enum NotoTheme {
    // MARK: - Colors
    // nōto. Design System — Centre de suivi parent
    // Grammaire visuelle : couleur = urgence (jamais décorative)
    enum Colors {
        // MARK: Core palette
        static let brand   = Color(hex: 0x2D3748)   // Slate — brand identity
        static let crimson = Color(hex: 0xDC2626)   // urgence rouge
        static let amber   = Color(hex: 0xCA8A04)   // avertissement
        static let cobalt  = Color(hex: 0x2563EB)   // liens, interactif, enrichissement
        static let green   = Color(hex: 0x34C759)   // positif, connecté

        // MARK: Adaptive semantic colors
        static let background       = adaptive(dark: 0x0A0A08, light: 0xFAF9F7)
        static let surface          = adaptive(dark: 0x1C1C1E, light: 0xFFFFFF)
        static let surfaceElevated  = adaptive(dark: 0x2C2C2E, light: 0xF5F3F0)
        static let surfaceSecondary = adaptive(dark: 0x2C2C2E, light: 0xF5F3F0)

        static let border = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.10)
        })

        static let textPrimary   = adaptive(dark: 0xF5F5F5, light: 0x1C1C1E)
        static let textSecondary = adaptive(dark: 0xA0A0A8, light: 0x787880)
        static let textTertiary  = adaptive(dark: 0x555555, light: 0x999999)

        static let shadow = adaptive(dark: 0x0A0A08, light: 0x0A0A08)

        // MARK: Semantic aliases
        static let card    = surface
        static let success = green
        static let warning = amber
        static let danger  = crimson
        static let info    = cobalt

        // MARK: Signal urgency (grammaire visuelle: couleur = signal)
        static func signalColor(_ urgency: SignalUrgency) -> Color {
            switch urgency {
            case .urgent:    crimson
            case .attention: amber
            case .positive:  green
            case .info:      cobalt
            }
        }

        // MARK: Service colors
        static let pronote = Color(hex: 0x8B46E6)
        static let ent     = cobalt

        // MARK: Legacy aliases (used by logo, story rings — will phase out)
        static let paper  = textPrimary
        static let indigo = brand

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
    // DM Serif Display (human: noms, matières, greeting)
    // Inter variable (functional: données, actions, metadata)
    // Grammaire: QUI/QUOI → serif · COMBIEN/QUAND → sans-serif
    enum Typography {
        /// Human register — names, subjects, greeting (DM Serif Display)
        static func human(_ size: CGFloat) -> Font {
            .custom("DMSerifDisplay-Regular", size: size)
        }

        /// Functional register — data, actions, metadata (Inter variable)
        static func functional(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
            // Inter is registered as the variable font "Inter" but
            // .system with .default design uses SF Pro which closely
            // matches Inter. For exact Inter, use .custom("Inter", size:)
            // once the variable font is confirmed to load.
        }

        /// Logo only (Pixelify Sans)
        static func pixel(_ size: CGFloat) -> Font {
            .custom("PixelifySans-Bold", size: size)
        }

        // MARK: Human presets (DM Serif Display)
        static let greeting    = human(28)       // "Bonjour Julien"
        static let childName   = human(16)       // "Gaston" in signal cards
        static let subjectName = human(16)       // "Mathématiques" in subject cards
        static let screenTitle = human(24)       // Screen titles

        // MARK: Functional presets (Inter / system)
        static let largeTitle  = functional(24, weight: .semibold)
        static let title       = functional(20, weight: .semibold)
        static let headline    = functional(16, weight: .semibold)
        static let body        = functional(14)
        static let caption     = functional(12)

        static let signalTitle = functional(14, weight: .medium) // N2 — signal title
        static let metadata    = functional(12)                  // N3 — detail (apply .opacity(0.65))

        static let data        = functional(16, weight: .semibold)
        static let dataLarge   = functional(22, weight: .semibold) // stat card values
        static let dataSmall   = functional(11)

        // Section labels: apply with .sectionLabel() modifier
        static let sectionLabel = functional(11, weight: .medium)
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let cardGap: CGFloat = 12   // between cards in same section
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Radius
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 14
        static let pill: CGFloat = 20
        static let card: CGFloat = 8       // shadcn --radius
    }
}

// MARK: - Signal Urgency

enum SignalUrgency {
    case urgent     // rouge — agir maintenant
    case attention  // ambre — à surveiller
    case positive   // vert — tout va bien
    case info       // bleu — enrichissement
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
    /// Standard nōto card — surface bg, subtle border, shadow.
    func notoCard() -> some View {
        self
            .background(NotoTheme.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: NotoTheme.Radius.card)
                    .stroke(NotoTheme.Colors.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
    }

    /// Signal card — tinted background + left accent border.
    /// Grammaire visuelle: le fond porte le signal, pas un dot.
    func signalCard(_ urgency: SignalUrgency) -> some View {
        let color = NotoTheme.Colors.signalColor(urgency)
        return self
            .background(color.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: NotoTheme.Radius.card,
                    bottomLeadingRadius: NotoTheme.Radius.card
                )
                .fill(color.opacity(0.5))
                .frame(width: 3)
            }
    }

    /// Section label style — 11px uppercase letterspaced, muted.
    func sectionLabelStyle() -> some View {
        self
            .font(NotoTheme.Typography.sectionLabel)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(1.5)
            .opacity(0.6)
    }
}
