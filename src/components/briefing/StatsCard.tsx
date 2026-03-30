import { View, Text, StyleSheet } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import type { ThemeColors } from "@/constants/theme";
import type { StatsData } from "@/lib/briefing/insights";

interface Props {
  stats: StatsData;
  theme: ThemeColors;
}

function barColor(pct: number, theme: ThemeColors): string {
  if (pct >= 0.7) return theme.accent;
  if (pct >= 0.5) return "#CA8A04";
  return theme.crimson;
}

export function StatsCard({ stats, theme }: Props) {
  const hasSubjects = stats.subjects.length > 0;
  const hasOverall = !!stats.overallAverage;

  return (
    <View style={styles.container}>
      {/* Counters row */}
      <View style={styles.countersRow}>
        {stats.counters.map((c) => (
          <View key={c.label} style={[styles.counter, { backgroundColor: theme.surfaceElevated, borderColor: theme.border }]}>
            <Text style={styles.counterIcon}>{c.icon}</Text>
            <Text style={[styles.counterValue, { color: theme.text }]}>{c.value}</Text>
            <Text style={[styles.counterLabel, { color: theme.textTertiary }]}>{c.label}</Text>
          </View>
        ))}
      </View>

      {/* Overall average */}
      {hasOverall && (
        <View style={[styles.overallCard, { backgroundColor: theme.surfaceElevated, borderColor: theme.border }]}>
          <View style={styles.overallHeader}>
            <Text style={[styles.overallLabel, { color: theme.textSecondary }]}>
              {stats.overallAverage!.label}
            </Text>
            <Text style={[styles.overallValue, { color: barColor(stats.overallAverage!.value / stats.overallAverage!.maxValue, theme) }]}>
              {stats.overallAverage!.value}{stats.overallAverage!.unit}
            </Text>
          </View>
          <View style={[styles.barBg, { backgroundColor: theme.border }]}>
            <View
              style={[
                styles.barFill,
                {
                  width: `${Math.min((stats.overallAverage!.value / stats.overallAverage!.maxValue) * 100, 100)}%`,
                  backgroundColor: barColor(stats.overallAverage!.value / stats.overallAverage!.maxValue, theme),
                },
              ]}
            />
          </View>
        </View>
      )}

      {/* Subject bars */}
      {hasSubjects && (
        <View style={[styles.subjectsCard, { backgroundColor: theme.surfaceElevated, borderColor: theme.border }]}>
          <Text style={[styles.subjectsTitle, { color: theme.textTertiary }]}>
            PAR MATIÈRE
          </Text>
          {stats.subjects.slice(0, 6).map((s) => (
            <View key={s.subject} style={styles.subjectRow}>
              <Text style={[styles.subjectName, { color: theme.text }]} numberOfLines={1}>
                {s.subject}
              </Text>
              <View style={styles.subjectBarContainer}>
                <View style={[styles.barBg, { backgroundColor: theme.border }]}>
                  <View
                    style={[
                      styles.barFill,
                      {
                        width: `${Math.round(s.average * 100)}%`,
                        backgroundColor: barColor(s.average, theme),
                      },
                    ]}
                  />
                  {s.classAverage !== undefined && (
                    <View
                      style={[
                        styles.classMarker,
                        { left: `${Math.round(s.classAverage * 100)}%`, backgroundColor: theme.textTertiary },
                      ]}
                    />
                  )}
                </View>
                <Text style={[styles.subjectPct, { color: barColor(s.average, theme) }]}>
                  {s.average20 !== undefined ? s.average20.toFixed(1) : Math.round(s.average * 20)}
                </Text>
              </View>
            </View>
          ))}
          {stats.subjects.some((s) => s.classAverage !== undefined) && (
            <View style={styles.legend}>
              <View style={[styles.legendDot, { backgroundColor: theme.textTertiary }]} />
              <Text style={[styles.legendText, { color: theme.textTertiary }]}>moy. classe</Text>
            </View>
          )}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: Spacing.sm, marginBottom: Spacing.md },

  // Counters
  countersRow: { flexDirection: "row", gap: Spacing.sm },
  counter: {
    flex: 1, alignItems: "center", gap: 2,
    paddingVertical: 10, borderRadius: BorderRadius.md, borderWidth: 1,
  },
  counterIcon: { fontSize: 18 },
  counterValue: { fontSize: FontSize.lg, fontFamily: Fonts.monoBold },
  counterLabel: { fontSize: FontSize.xs, fontFamily: Fonts.regular },

  // Overall
  overallCard: {
    padding: 12, borderRadius: BorderRadius.md, borderWidth: 1, gap: 8,
  },
  overallHeader: {
    flexDirection: "row", justifyContent: "space-between", alignItems: "center",
  },
  overallLabel: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  overallValue: { fontSize: FontSize.lg, fontFamily: Fonts.monoBold },

  // Bars
  barBg: { height: 6, borderRadius: 3, position: "relative" },
  barFill: { height: 6, borderRadius: 3 },
  classMarker: {
    position: "absolute", top: -1, width: 2, height: 8, borderRadius: 1,
  },

  // Subjects
  subjectsCard: {
    padding: 12, borderRadius: BorderRadius.md, borderWidth: 1, gap: 8,
  },
  subjectsTitle: {
    fontSize: 10, fontFamily: Fonts.medium, letterSpacing: 1.5, marginBottom: 2,
  },
  subjectRow: { gap: 4 },
  subjectName: { fontSize: FontSize.xs, fontFamily: Fonts.medium },
  subjectBarContainer: { flexDirection: "row", alignItems: "center", gap: 6 },
  subjectPct: { fontSize: FontSize.xs, fontFamily: Fonts.mono, width: 32, textAlign: "right" },

  // Legend
  legend: { flexDirection: "row", alignItems: "center", gap: 4, marginTop: 4 },
  legendDot: { width: 2, height: 8, borderRadius: 1 },
  legendText: { fontSize: 9, fontFamily: Fonts.regular },
});
