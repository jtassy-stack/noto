import { View, Text, StyleSheet } from "react-native";
import { Fonts, Spacing } from "@/constants/theme";
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
    <View style={[styles.container, { backgroundColor: "#FFFFFF", borderColor: theme.border }]}>
      {insights.map((insight, i) => (
        <View key={i} style={[styles.row, i > 0 && { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: theme.border }]}>
          <View style={[styles.badge, { backgroundColor: accentMap[insight.accent] + "1F" }]}>
            <Text style={[styles.badgeText, { color: accentMap[insight.accent] }]}>
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
    borderRadius: 12,
    borderWidth: 1,
    padding: 16,
    marginBottom: Spacing.md,
  },
  row: {
    gap: 6,
    paddingVertical: 8,
  },
  badge: {
    alignSelf: "flex-start",
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 4,
  },
  badgeText: {
    fontSize: 10,
    fontFamily: Fonts.semiBold,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  text: {
    fontSize: 13,
    fontFamily: Fonts.regular,
    lineHeight: 20,
  },
});
