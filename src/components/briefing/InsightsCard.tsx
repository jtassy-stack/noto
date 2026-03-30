import { View, Text, StyleSheet } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import type { ThemeColors } from "@/constants/theme";
import type { TextInsight } from "@/lib/briefing/insights";

interface Props {
  insights: TextInsight[];
  theme: ThemeColors;
}

export function InsightsCard({ insights, theme }: Props) {
  if (insights.length === 0) return null;

  const accentMap: Record<string, string> = {
    green: theme.accent,
    red: theme.crimson,
    amber: "#CA8A04",
    default: theme.textSecondary,
  };

  return (
    <View style={[styles.container, { backgroundColor: theme.surfaceElevated, borderColor: theme.border }]}>
      {insights.map((insight, i) => (
        <View key={i} style={[styles.row, i > 0 && { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: theme.border }]}>
          <View style={[styles.label, { backgroundColor: accentMap[insight.accent] + "18" }]}>
            <Text style={[styles.labelText, { color: accentMap[insight.accent] }]}>
              {insight.label}
            </Text>
          </View>
          <Text style={[styles.text, { color: theme.text }]}>
            {insight.text}
          </Text>
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: Spacing.md,
    overflow: "hidden",
  },
  row: {
    padding: 12,
    gap: 6,
  },
  label: {
    alignSelf: "flex-start",
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 4,
  },
  labelText: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.semiBold,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  text: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    lineHeight: 20,
  },
});
