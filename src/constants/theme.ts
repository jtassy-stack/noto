/**
 * nōto. design tokens — Option B (Sobre)
 * Inter for UI, Space Mono for data, Pixelify Sans for logo.
 * Light mode default, dark mode supported.
 */

export const Palette = {
  // Primary
  shadow: "#0A0A08",
  paper: "#F5F3EE",
  oneUp: "#5BD45B",
  oneUpLight: "#2EA82E", // adjusted for light bg contrast

  // Secondary
  indigo: "#2B2B6E",
  dmg: "#9BBB0F",
  dmgLight: "#7A9A0A",
  mist: "#B0B0D0",
  graphite: "#555555",
  charbon: "#222222",

  // Semantic
  crimson: "#DC2626",
  crimsonLight: "#C02020",
  cherry: "#BE123C",
  cobalt: "#2563EB",
  sky: "#38BDF8",
  amber: "#CA8A04",
  amberLight: "#A07004",
  forest: "#0f380f",

  // Retrogaming
  coin: "#EAB308",
  warp: "#7C3AED",
  shield: "#0891B2",

  // Light mode surfaces
  white: "#FFFFFF",
  cardBorder: "#E5E2DC",
  subtleBg: "#EDEBE6",
} as const;

export type ThemeMode = "light" | "dark";

export interface ThemeColors {
  background: string;
  surface: string;
  surfaceElevated: string;
  border: string;
  text: string;
  textSecondary: string;
  textTertiary: string;
  accent: string;
  gradeExcellent: string;
  gradeGood: string;
  gradeAverage: string;
  gradeFail: string;
  crimson: string;
  tabBarBg: string;
  tabBarBorder: string;
}

export const LightTheme: ThemeColors = {
  background: Palette.paper,
  surface: Palette.white,
  surfaceElevated: Palette.subtleBg,
  border: Palette.cardBorder,
  text: Palette.shadow,
  textSecondary: Palette.graphite,
  textTertiary: "#888888",
  accent: Palette.oneUpLight,
  gradeExcellent: Palette.oneUpLight,
  gradeGood: Palette.dmgLight,
  gradeAverage: Palette.amberLight,
  gradeFail: Palette.crimsonLight,
  crimson: Palette.crimsonLight,
  tabBarBg: Palette.white,
  tabBarBorder: Palette.cardBorder,
};

export const DarkTheme: ThemeColors = {
  background: Palette.shadow,
  surface: Palette.charbon,
  surfaceElevated: "#1C1C1C",
  border: Palette.graphite,
  text: Palette.paper,
  textSecondary: Palette.mist,
  textTertiary: Palette.graphite,
  accent: Palette.oneUp,
  gradeExcellent: Palette.oneUp,
  gradeGood: Palette.dmg,
  gradeAverage: Palette.amber,
  gradeFail: Palette.crimson,
  crimson: Palette.crimson,
  tabBarBg: Palette.charbon,
  tabBarBorder: Palette.graphite,
};

export const Spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
  xxl: 48,
} as const;

export const FontSize = {
  xs: 10,
  sm: 12,
  md: 14,
  lg: 16,
  xl: 20,
  xxl: 24,
  hero: 34,
} as const;

export const BorderRadius = {
  sm: 4,
  md: 6,
  lg: 8,
  full: 9999,
} as const;

export const Fonts = {
  // UI (Inter)
  regular: "Inter_400Regular",
  medium: "Inter_500Medium",
  semiBold: "Inter_600SemiBold",
  bold: "Inter_700Bold",
  // Data (Space Mono)
  mono: "SpaceMono_400Regular",
  monoBold: "SpaceMono_700Bold",
  // Logo (Pixelify Sans)
  pixel: "PixelifySans_700Bold",
  // Accent (Instrument Serif)
  serif: "InstrumentSerif_400Regular_Italic",
} as const;

export function gradeColor(value: number, outOf: number, theme: ThemeColors): string {
  const pct = (value / outOf) * 100;
  if (pct >= 70) return theme.gradeExcellent;
  if (pct >= 60) return theme.gradeGood;
  if (pct >= 50) return theme.gradeAverage;
  return theme.gradeFail;
}
