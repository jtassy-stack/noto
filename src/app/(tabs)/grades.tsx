import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getGradesByChild } from "@/lib/database/repository";
import { gradeColor } from "@/constants/theme";
import { EntBlogScreen } from "@/components/ent/BlogScreen";
import type { Grade } from "@/types";

interface SubjectAvg {
  subject: string;
  average: number;
  count: number;
}

export default function GradesScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [grades, setGrades] = useState<Grade[]>([]);

  useEffect(() => {
    if (!activeChild || activeChild.source === "ent") return;
    getGradesByChild(activeChild.id).then(setGrades);
  }, [activeChild]);

  // ENT child → Blog screen
  if (activeChild?.source === "ent") {
    return <EntBlogScreen />;
  }

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Connectez un compte.</Text>
      </View>
    );
  }

  if (grades.length === 0) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Aucune note pour le moment. Synchronisez depuis l'accueil.
        </Text>
      </View>
    );
  }

  // Compute subject averages
  const subjectMap = new Map<string, { total: number; count: number }>();
  for (const g of grades) {
    const normalized = (g.value / g.outOf) * 20;
    const existing = subjectMap.get(g.subject) ?? { total: 0, count: 0 };
    existing.total += normalized;
    existing.count += 1;
    subjectMap.set(g.subject, existing);
  }

  const subjectAverages: SubjectAvg[] = Array.from(subjectMap.entries())
    .map(([subject, { total, count }]) => ({ subject, average: total / count, count }))
    .sort((a, b) => b.average - a.average);

  const generalAvg = subjectAverages.reduce((sum, s) => sum + s.average, 0) / subjectAverages.length;

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      <View style={[styles.avgCard, { backgroundColor: theme.surface, borderColor: theme.accent }]}>
        <Text style={[styles.avgLabel, { color: theme.textSecondary }]}>MOYENNE GÉNÉRALE</Text>
        <Text style={[styles.avgValue, { color: theme.accent }]}>{generalAvg.toFixed(1)}</Text>
        <Text style={[styles.avgSub, { color: theme.textTertiary }]}>{subjectAverages.length} matières · {grades.length} notes</Text>
      </View>

      <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>PAR MATIÈRE</Text>
      {subjectAverages.map((s) => {
        const color = gradeColor(s.average, 20, theme);
        const pct = Math.min(s.average / 20, 1);
        return (
          <View key={s.subject} style={styles.gradeRow}>
            <View style={styles.gradeInfo}>
              <View style={styles.gradeHeader}>
                <Text style={[styles.gradeSubject, { color: theme.text }]}>{s.subject}</Text>
                <View style={styles.gradeValueRow}>
                  <Text style={[styles.gradeValue, { color }]}>{s.average.toFixed(1)}</Text>
                  <Text style={[styles.gradeOutOf, { color: theme.textTertiary }]}>/20</Text>
                </View>
              </View>
              <View style={[styles.gradeBarBg, { backgroundColor: theme.surfaceElevated }]}>
                <View style={[styles.gradeBarFill, { width: `${pct * 100}%`, backgroundColor: color }]} />
              </View>
            </View>
          </View>
        );
      })}

      <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.lg }]}>DERNIÈRES NOTES</Text>
      {grades.slice(0, 15).map((g) => {
        const pct = g.outOf > 0 ? g.value / g.outOf : 0;
        const color = gradeColor(g.value, g.outOf, theme);
        return (
          <View key={g.id} style={styles.gradeRow}>
            <View style={styles.gradeInfo}>
              <View style={styles.gradeHeader}>
                <Text style={[styles.gradeSubject, { color: theme.text }]}>{g.subject}</Text>
                <View style={styles.gradeValueRow}>
                  <Text style={[styles.gradeValue, { color }]}>{g.value}</Text>
                  <Text style={[styles.gradeOutOf, { color: theme.textTertiary }]}>/{g.outOf}</Text>
                </View>
              </View>
              {g.comment ? (
                <Text style={[styles.gradeMeta, { color: theme.textTertiary }]}>{g.date} · {g.comment}</Text>
              ) : (
                <Text style={[styles.gradeMeta, { color: theme.textTertiary }]}>{g.date}</Text>
              )}
              <View style={[styles.gradeBarBg, { backgroundColor: theme.surfaceElevated }]}>
                <View style={[styles.gradeBarFill, { width: `${Math.min(pct * 100, 100)}%`, backgroundColor: color }]} />
              </View>
            </View>
          </View>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  empty: { flex: 1, justifyContent: "center", alignItems: "center", padding: Spacing.lg },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center" },
  avgCard: { alignItems: "center", padding: Spacing.lg, borderRadius: BorderRadius.lg, borderWidth: 1, marginBottom: Spacing.lg, gap: 4 },
  avgLabel: { fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5 },
  avgValue: { fontSize: 36, fontFamily: Fonts.monoBold },
  avgSub: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  sectionLabel: { fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5, marginBottom: Spacing.sm },
  gradeRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: 8,
  },
  gradeInfo: { flex: 1, gap: 2 },
  gradeHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  gradeValueRow: {
    flexDirection: "row",
    alignItems: "baseline",
  },
  gradeSubject: { fontSize: FontSize.md, fontFamily: Fonts.medium },
  gradeMeta: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  gradeValue: { fontSize: FontSize.md, fontFamily: Fonts.monoBold },
  gradeOutOf: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  gradeBarBg: { height: 3, borderRadius: 1.5, marginTop: 6 },
  gradeBarFill: { height: 3, borderRadius: 1.5 },
});
