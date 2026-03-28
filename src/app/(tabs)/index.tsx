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
import { getConversationCredentials } from "@/lib/ent/conversation";
import { fetchBlogs, fetchTimeline, type BlogPost, type TimelineNotification } from "@/lib/ent/pcn-data";
import type { Grade, ScheduleEntry, Homework } from "@/types";

// --- ENT Dashboard (blog + timeline for PCN children) ---

function EntDashboard({ childName }: { childName: string }) {
  const theme = useTheme();
  const [blogs, setBlogs] = useState<BlogPost[]>([]);
  const [timeline, setTimeline] = useState<TimelineNotification[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      const creds = await getConversationCredentials();
      if (!creds) { setLoading(false); return; }

      try {
        const [b, t] = await Promise.all([
          fetchBlogs(creds),
          fetchTimeline(creds),
        ]);
        setBlogs(b);
        setTimeline(t);
      } catch (e) {
        console.warn("[nōto] ENT data error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [childName]);

  const notifIcon: Record<string, string> = {
    MESSAGERIE: "✉️",
    BLOG: "📝",
    SCHOOLBOOK: "📒",
  };

  return (
    <ScrollView
      style={[entStyles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={entStyles.content}
    >
      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}

      {/* Blog section */}
      {blogs.length > 0 && (
        <>
          <Text style={[entStyles.sectionLabel, { color: theme.textTertiary }]}>
            BLOG DE LA CLASSE
          </Text>
          {blogs.slice(0, 5).map((b) => {
            const date = b.modified ? new Date(b.modified) : null;
            const dateStr = date
              ? date.toLocaleDateString("fr-FR", { day: "numeric", month: "short" })
              : "";
            return (
              <View
                key={b.id}
                style={[entStyles.blogCard, { backgroundColor: theme.surface, borderColor: theme.border }]}
              >
                <View style={entStyles.blogContent}>
                  <Text style={[entStyles.blogTitle, { color: theme.text }]} numberOfLines={2}>
                    {b.title}
                  </Text>
                  <Text style={[entStyles.blogDate, { color: theme.textTertiary }]}>
                    {dateStr}
                  </Text>
                </View>
              </View>
            );
          })}
        </>
      )}

      {/* Timeline / Fil d'actu */}
      {timeline.length > 0 && (
        <>
          <Text style={[entStyles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.lg }]}>
            FIL D'ACTUALITÉ
          </Text>
          {timeline.map((n) => {
            const date = n.date ? new Date(n.date) : null;
            const dateStr = date
              ? date.toLocaleDateString("fr-FR", { day: "numeric", month: "short" })
              : "";
            const icon = notifIcon[n.type] || "📌";

            return (
              <View
                key={n.id}
                style={[entStyles.timelineRow, { backgroundColor: theme.surface, borderColor: theme.border }]}
              >
                <Text style={entStyles.timelineIcon}>{icon}</Text>
                <View style={entStyles.timelineContent}>
                  <Text style={[entStyles.timelineMsg, { color: theme.text }]} numberOfLines={2}>
                    {n.message}
                  </Text>
                  <Text style={[entStyles.timelineDate, { color: theme.textTertiary }]}>
                    {dateStr}{n.sender ? ` · ${n.sender}` : ""}
                  </Text>
                </View>
              </View>
            );
          })}
        </>
      )}

      {!loading && blogs.length === 0 && timeline.length === 0 && (
        <View style={entStyles.emptyState}>
          <Text style={[entStyles.emptyText, { color: theme.textTertiary }]}>
            Aucune actualité pour le moment.
          </Text>
        </View>
      )}
    </ScrollView>
  );
}

const entStyles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  sectionLabel: { fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5, marginBottom: Spacing.sm },
  blogCard: {
    flexDirection: "row", padding: 14, borderRadius: BorderRadius.md,
    borderWidth: 1, marginBottom: 6, gap: Spacing.sm,
  },
  blogContent: { flex: 1, gap: 4 },
  blogTitle: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, lineHeight: 20 },
  blogDate: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  timelineRow: {
    flexDirection: "row", alignItems: "flex-start", padding: 12,
    borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: 4, gap: Spacing.sm,
  },
  timelineIcon: { fontSize: 18, marginTop: 2 },
  timelineContent: { flex: 1, gap: 3 },
  timelineMsg: { fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 18 },
  timelineDate: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  emptyState: { justifyContent: "center", alignItems: "center", paddingTop: Spacing.xxl },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center" },
});

// --- Pronote Dashboard ---

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
          Connectez votre compte Pronote ou ENT pour commencer.
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

  // ENT-only child — show blog + timeline from PCN
  if (activeChild.source === "ent" && !activeChild.hasGrades) {
    return <EntDashboard childName={activeChild.firstName} />;
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
  card: {
    borderRadius: BorderRadius.md,
    padding: Spacing.lg,
    borderWidth: 1,
  },
  cardTitle: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.semiBold,
    marginBottom: Spacing.sm,
  },
  cardBody: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    lineHeight: 22,
  },
});
