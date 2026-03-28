import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { useSync } from "@/hooks/useSync";
import {
  getGradesByChild,
  getScheduleByChild,
  getHomeworkByChild,
} from "@/lib/database/repository";
import { gradeColor } from "@/constants/theme";
import type { Grade, ScheduleEntry, Homework } from "@/types";

export default function DashboardScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const { sync, syncing } = useSync();
  const [grades, setGrades] = useState<Grade[]>([]);
  const [schedule, setSchedule] = useState<ScheduleEntry[]>([]);
  const [homework, setHomework] = useState<Homework[]>([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!activeChild) return;

    async function load() {
      const today = new Date().toISOString().split("T")[0]!;
      const tomorrow = new Date(Date.now() + 86400000).toISOString().split("T")[0]!;

      const [g, s, h] = await Promise.all([
        getGradesByChild(activeChild!.id),
        getScheduleByChild(activeChild!.id, today, tomorrow),
        getHomeworkByChild(activeChild!.id, today),
      ]);
      setGrades(g);
      setSchedule(s);
      setHomework(h);
      setLoaded(true);
    }

    load();
  }, [activeChild]);

  // Auto-sync on first load if no data
  useEffect(() => {
    if (loaded && activeChild && grades.length === 0 && schedule.length === 0) {
      sync(activeChild.id).then(() => {
        // Reload after sync
        const today = new Date().toISOString().split("T")[0]!;
        const tomorrow = new Date(Date.now() + 86400000).toISOString().split("T")[0]!;
        Promise.all([
          getGradesByChild(activeChild.id),
          getScheduleByChild(activeChild.id, today, tomorrow),
          getHomeworkByChild(activeChild.id, today),
        ]).then(([g, s, h]) => {
          setGrades(g);
          setSchedule(s);
          setHomework(h);
        });
      });
    }
  }, [loaded, activeChild]);

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyTitle, { color: theme.text }]}>
          Bienvenue sur nōto.
        </Text>
        <Text style={[styles.emptyText, { color: theme.textSecondary }]}>
          Connectez votre compte Pronote pour voir les données de votre enfant.
        </Text>
        <Pressable
          style={[styles.connectBtn, { backgroundColor: theme.accent }]}
          onPress={() => router.push("/auth/")}
        >
          <Text style={styles.connectBtnText}>Connecter un compte</Text>
        </Pressable>
      </View>
    );
  }

  const recentGrades = grades.slice(0, 5);
  const todaySchedule = schedule.filter((s) => !s.isCancelled);
  const pendingHomework = homework.filter((h) => !h.isDone);

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {/* Class info */}
      <View style={styles.classRow}>
        <Text style={[styles.className, { color: theme.textSecondary }]}>
          {activeChild.className}
        </Text>
        {syncing && <ActivityIndicator size="small" color={theme.accent} />}
        {!syncing && (
          <Pressable onPress={() => sync(activeChild.id)}>
            <Text style={[styles.syncBtn, { color: theme.accent }]}>↻ Sync</Text>
          </Pressable>
        )}
      </View>

      {/* Today's Schedule */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>
        AUJOURD'HUI
      </Text>
      {todaySchedule.length === 0 && !syncing && (
        <Text style={[styles.emptySection, { color: theme.textTertiary }]}>
          {loaded ? "Aucun cours aujourd'hui" : "Chargement..."}
        </Text>
      )}
      {todaySchedule.map((s) => (
        <View
          key={s.id}
          style={[styles.scheduleRow, { backgroundColor: theme.surface, borderColor: theme.border }]}
        >
          <Text style={[styles.scheduleTime, { color: theme.accent }]}>
            {new Date(s.startTime).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })}
          </Text>
          <View style={styles.scheduleInfo}>
            <Text style={[styles.scheduleSubject, { color: theme.text }]}>
              {s.subject}
            </Text>
            <Text style={[styles.scheduleMeta, { color: theme.textSecondary }]}>
              {[s.teacher, s.room].filter(Boolean).join(" · ")}
            </Text>
          </View>
        </View>
      ))}

      {/* Recent Grades */}
      {recentGrades.length > 0 && (
        <>
          <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.lg }]}>
            DERNIÈRES NOTES
          </Text>
          {recentGrades.map((g) => (
            <View
              key={g.id}
              style={[styles.gradeRow, { backgroundColor: theme.surface, borderColor: theme.border }]}
            >
              <View style={styles.gradeInfo}>
                <Text style={[styles.gradeSubject, { color: theme.text }]}>
                  {g.subject}
                </Text>
                <Text style={[styles.gradeDate, { color: theme.textTertiary }]}>
                  {g.date}
                </Text>
              </View>
              <Text
                style={[
                  styles.gradeValue,
                  { color: gradeColor(g.value, g.outOf, theme) },
                ]}
              >
                {g.value}/{g.outOf}
              </Text>
            </View>
          ))}
        </>
      )}

      {/* Upcoming Homework */}
      {pendingHomework.length > 0 && (
        <>
          <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.lg }]}>
            DEVOIRS À VENIR ({pendingHomework.length})
          </Text>
          {pendingHomework.slice(0, 5).map((h) => (
            <View
              key={h.id}
              style={[styles.homeworkRow, { backgroundColor: theme.surface, borderColor: theme.border }]}
            >
              <View style={styles.homeworkInfo}>
                <Text style={[styles.homeworkSubject, { color: theme.text }]}>
                  {h.subject}
                </Text>
                <Text
                  style={[styles.homeworkDesc, { color: theme.textSecondary }]}
                  numberOfLines={2}
                >
                  {h.description}
                </Text>
              </View>
              <Text style={[styles.homeworkDate, { color: theme.accent }]}>
                {h.dueDate}
              </Text>
            </View>
          ))}
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  classRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: Spacing.md,
  },
  className: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.medium,
    letterSpacing: 1,
    textTransform: "uppercase",
  },
  syncBtn: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.medium,
  },
  sectionLabel: {
    fontSize: 11,
    fontFamily: Fonts.medium,
    letterSpacing: 1.5,
    marginBottom: Spacing.sm,
  },
  emptySection: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    marginBottom: Spacing.md,
  },

  // Schedule
  scheduleRow: {
    flexDirection: "row",
    alignItems: "center",
    padding: 12,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: 4,
    gap: Spacing.md,
  },
  scheduleTime: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.mono,
  },
  scheduleInfo: { flex: 1, gap: 2 },
  scheduleSubject: {
    fontSize: FontSize.md,
    fontFamily: Fonts.medium,
  },
  scheduleMeta: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
  },

  // Grades
  gradeRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    padding: 12,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: 4,
  },
  gradeInfo: { flex: 1, gap: 2 },
  gradeSubject: {
    fontSize: FontSize.md,
    fontFamily: Fonts.medium,
  },
  gradeDate: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
  },
  gradeValue: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.monoBold,
  },

  // Homework
  homeworkRow: {
    flexDirection: "row",
    alignItems: "flex-start",
    padding: 12,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: 4,
    gap: Spacing.sm,
  },
  homeworkInfo: { flex: 1, gap: 2 },
  homeworkSubject: {
    fontSize: FontSize.md,
    fontFamily: Fonts.medium,
  },
  homeworkDesc: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    lineHeight: 18,
  },
  homeworkDate: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.mono,
  },

  // Empty state
  empty: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    padding: Spacing.xl,
    gap: Spacing.md,
  },
  emptyTitle: {
    fontSize: FontSize.xl,
    fontFamily: Fonts.bold,
  },
  emptyText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    textAlign: "center",
    lineHeight: 22,
  },
  connectBtn: {
    borderRadius: BorderRadius.md,
    paddingVertical: 14,
    paddingHorizontal: Spacing.xl,
    marginTop: Spacing.sm,
  },
  connectBtnText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.semiBold,
    color: "#FFFFFF",
  },
});
