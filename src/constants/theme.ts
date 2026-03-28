/**
 * nōto. design tokens
 * Sobre et premium — Notion/Linear aesthetic with dark-first approach.
 */

export const Colors = {
  // Core
  background: "#0A0A0A",
  surface: "#141414",
  surfaceElevated: "#1C1C1C",
  border: "#262626",
  borderSubtle: "#1C1C1C",

  // Text
  text: "#FAFAFA",
  textSecondary: "#A0A0A0",
  textTertiary: "#666666",

  // Accent — subtle warm tone
  accent: "#E8D5B7", // champagne
  accentMuted: "rgba(232, 213, 183, 0.15)",

  // Semantic
  success: "#4ADE80",
  warning: "#FBBF24",
  error: "#F87171",
  info: "#60A5FA",

  // Grades
  gradeExcellent: "#4ADE80",
  gradeGood: "#A3E635",
  gradeAverage: "#FBBF24",
  gradePoor: "#FB923C",
  gradeFail: "#F87171",
} as const;

export const Spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
  xxl: 48,
} as const;

export const FontSize = {
  xs: 11,
  sm: 13,
  md: 15,
  lg: 17,
  xl: 20,
  xxl: 28,
  hero: 34,
} as const;

export const BorderRadius = {
  sm: 6,
  md: 10,
  lg: 16,
  full: 9999,
} as const;

export function gradeColor(value: number, outOf: number): string {
  const pct = (value / outOf) * 100;
  if (pct >= 80) return Colors.gradeExcellent;
  if (pct >= 65) return Colors.gradeGood;
  if (pct >= 50) return Colors.gradeAverage;
  if (pct >= 35) return Colors.gradePoor;
  return Colors.gradeFail;
}
