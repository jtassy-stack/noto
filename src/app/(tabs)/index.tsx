import { useEffect, useState, useMemo } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator, RefreshControl } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius, gradeColor } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { useSync } from "@/hooks/useSync";
import {
  getGradesByChild,
  getScheduleByChild,
  getHomeworkByChild,
  setChildSetting,
} from "@/lib/database/repository";
import { getConversationCredentials, fetchConversationInbox, filterMessagesByChild } from "@/lib/ent/conversation";
import { fetchTimeline, fetchSchoolbookWord, fetchSchoolbookForChild } from "@/lib/ent/pcn-data";
import { buildBriefing, buildEntBriefing, type Briefing, type BriefingItem } from "@/lib/briefing/engine";
import { isAvailable as isMLAvailable, generateSummary } from "../../../modules/on-device-ml";
import { generateTextSummary } from "@/lib/briefing/text-generator";
import {
  extractTextInsights, extractEntTextInsights,
  extractStats, extractEntStats,
  type TextInsight, type StatsData,
} from "@/lib/briefing/insights";
import { InsightsCard } from "@/components/briefing/InsightsCard";
import { StatsCard } from "@/components/briefing/StatsCard";
import type { Grade, ScheduleEntry, Homework } from "@/types";

// --- Briefing Card Component ---

// handleBriefingTap is defined inside DashboardScreen to access activeChild

function BriefingCard({ item, theme, onPress }: { item: BriefingItem; theme: ReturnType<typeof useTheme>; onPress?: (item: BriefingItem) => void }) {
  const accentMap = {
    green: theme.accent,
    red: theme.crimson,
    amber: "#CA8A04",
    default: theme.textSecondary,
  };
  const dotColor = accentMap[item.accent ?? "default"];
  const isTappable = onPress && (!!item.data || item.type === "messages_unread");

  const content = (
    <>
      <View style={[cardStyles.dot, { backgroundColor: dotColor }]} />
      <View style={cardStyles.content}>
        <View style={cardStyles.titleRow}>
          <Text style={[cardStyles.title, { color: theme.text }]} numberOfLines={2}>
            {item.title}
          </Text>
          {item.value && (
            <Text style={[cardStyles.value, { color: dotColor }]}>
              {item.value}
            </Text>
          )}
        </View>
        {item.subtitle && (
          <Text style={[cardStyles.subtitle, { color: theme.textTertiary }]} numberOfLines={2}>
            {item.subtitle}
          </Text>
        )}
      </View>
    </>
  );

  if (isTappable) {
    return (
      <Pressable
        style={({ pressed }) => [cardStyles.row, pressed && { opacity: 0.6 }]}
        onPress={() => onPress!(item)}
      >
        {content}
      </Pressable>
    );
  }

  return <View style={cardStyles.row}>{content}</View>;
}

const cardStyles = StyleSheet.create({
  row: {
    flexDirection: "row",
    alignItems: "flex-start",
    paddingVertical: 10,
    gap: Spacing.sm,
  },
  dot: { width: 6, height: 6, borderRadius: 3, marginTop: 7 },
  content: { flex: 1, gap: 3 },
  titleRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "flex-start", gap: Spacing.sm },
  title: { fontSize: FontSize.md, fontFamily: Fonts.medium, flex: 1, lineHeight: 20 },
  value: { fontSize: FontSize.md, fontFamily: Fonts.monoBold },
  subtitle: { fontSize: FontSize.xs, fontFamily: Fonts.regular, lineHeight: 16 },
});

// --- Main Screen ---

export default function DashboardScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const { sync, syncing } = useSync();
  const [briefing, setBriefing] = useState<Briefing | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [aiSummary, setAiSummary] = useState<string | null>(null);
  const [aiLoading, setAiLoading] = useState(false);
  const [insights, setInsights] = useState<TextInsight[]>([]);
  const [stats, setStats] = useState<StatsData | null>(null);
  const [period, setPeriod] = useState<"jour" | "semaine" | "semestre">("jour");

  // All grades (unfiltered) — loaded once, filtered by period for display
  const [allGrades, setAllGrades] = useState<Grade[]>([]);
  const [allSchedule, setAllSchedule] = useState<ScheduleEntry[]>([]);
  const [allHomework, setAllHomework] = useState<Homework[]>([]);

  async function handleBriefingTap(item: BriefingItem) {
    const data = item.data as Record<string, unknown> | undefined;
    if (!data) {
      if (item.type === "messages_unread") router.push("/(tabs)/messages");
      return;
    }

    const type = data.type as string | undefined;
    const message = data.message as string | undefined;
    const sender = data.sender as string | undefined;
    const date = data.date as string | undefined;
    const wordId = data.wordId as string | undefined;
    const wordTitle = data.wordTitle as string | undefined;
    const dateStr = date
      ? new Date(date).toLocaleDateString("fr-FR", { day: "numeric", month: "short" })
      : "";

    if (type === "SCHOOLBOOK" && wordId) {
      const creds = await getConversationCredentials();
      const entChildId = activeChild?.entUserId;
      if (creds && entChildId) {
        const word = await fetchSchoolbookWord(creds, wordId, entChildId);
        if (word) {
          router.push({
            pathname: "/detail",
            params: {
              title: word.title || wordTitle || item.title,
              from: word.sender || sender || "",
              date: word.date ? new Date(word.date).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" }) : dateStr,
              type: "schoolbook",
              body: word.text,
            },
          });
          return;
        }
      }
      // Fallback: WebView
      router.push({
        pathname: "/webview",
        params: { title: wordTitle || item.title, path: `/schoolbook#/word/${wordId}` },
      });
    } else if (type === "MESSAGERIE" || item.type === "messages_unread") {
      router.push("/(tabs)/messages");
    } else if (type === "BLOG") {
      const billetMatch = (message ?? "").match(/a publié un billet\s+(.+?)(?:\s+dans le blog|$)/i);
      const title = billetMatch ? billetMatch[1]!.trim() : item.title;
      router.push({
        pathname: "/detail",
        params: { title, from: sender ?? "", date: dateStr, type: "timeline", body: message ?? item.title },
      });
    }
  }

  async function loadBriefing() {
    if (!activeChild) return;

    const isEnt = activeChild.source === "ent" && !activeChild.hasGrades;

    if (isEnt) {
      const creds = await getConversationCredentials();

      // Backfill entUserId if missing
      if (creds && !activeChild.entUserId) {
        try {
          // Login first
          await fetch(`${creds.apiBaseUrl}/auth/login`, {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
            redirect: "follow",
          });
          const personRes = await fetch(`${creds.apiBaseUrl}/userbook/api/person`, {
            headers: { Accept: "application/json" },
          });
          if (personRes.ok) {
            const personData = await personRes.json();
            const results = personData.result ?? personData;
            if (Array.isArray(results)) {
              for (const entry of results) {
                const relatedName = String(entry.relatedName ?? "");
                const relatedId = String(entry.relatedId ?? "");
                // Match by first name
                if (relatedId && relatedName.includes(activeChild.firstName)) {
                  await setChildSetting(activeChild.id, "ent_user_id", relatedId);
                  activeChild.entUserId = relatedId;
                  console.log("[nōto] Backfilled entUserId for", activeChild.firstName, ":", relatedId);
                  break;
                }
              }
            }
          }
        } catch (e) {
          console.warn("[nōto] entUserId backfill failed:", e);
        }
      }

      // ENT child — build from schoolbook + messages + timeline
      if (!creds) {
        setBriefing(buildEntBriefing(activeChild.firstName, {
          timeline: [], unreadMessages: 0, recentMessages: [],
        }));
        setLoaded(true);
        return;
      }
      try {
        const entChildId = activeChild.entUserId;
        const [timeline, inbox, schoolbookWords] = await Promise.all([
          fetchTimeline(creds).catch(() => []),
          fetchConversationInbox(creds, 0).catch(() => ({ messages: [] })),
          entChildId ? fetchSchoolbookForChild(creds, entChildId).catch(() => []) : Promise.resolve([]),
        ]);

        const filtered = activeChild.className
          ? filterMessagesByChild(inbox.messages, activeChild.className)
          : inbox.messages;
        const unreadMessages = filtered.filter((m) => m.unread).length;
        const recentMessages = filtered.slice(0, 3).map((m) => ({
          from: m.from, subject: m.subject, date: m.date,
        }));

        const entBriefingData = { timeline, unreadMessages, recentMessages, schoolbookWords };
        setBriefing(buildEntBriefing(activeChild.firstName, entBriefingData));
        setInsights(extractEntTextInsights(schoolbookWords, unreadMessages));
        const blogCount = timeline.filter((n) => n.type === "BLOG").length;
        setStats(extractEntStats(schoolbookWords, unreadMessages, blogCount));
      } catch {
        setBriefing(buildEntBriefing(activeChild.firstName, {
          timeline: [], unreadMessages: 0, recentMessages: [],
        }));
      }
    } else {
      // Pronote child — fetch all data, filter by period for display
      const today = new Date();
      const todayStr = today.toISOString().split("T")[0]!;
      // Fetch semester-wide schedule + homework (broadest range)
      const semesterStart = new Date(today);
      semesterStart.setMonth(semesterStart.getMonth() - 6);
      const semesterEnd = new Date(today);
      semesterEnd.setMonth(semesterEnd.getMonth() + 1);

      const [g, s, h] = await Promise.all([
        getGradesByChild(activeChild.id),
        getScheduleByChild(activeChild.id, semesterStart.toISOString().split("T")[0]!, semesterEnd.toISOString().split("T")[0]!),
        getHomeworkByChild(activeChild.id, todayStr),
      ]);

      setAllGrades(g);
      setAllSchedule(s);
      setAllHomework(h);
    }
    setLoaded(true);
  }

  // Filter data by period for Pronote children
  const periodData = useMemo(() => {
    if (!activeChild || activeChild.source === "ent") return null;
    const now = new Date();
    const todayStr = now.toISOString().split("T")[0]!;
    const tomorrowStr = new Date(now.getTime() + 86400000).toISOString().split("T")[0]!;

    let gradesCutoff: Date;
    let scheduleDateStart: string;
    let scheduleDateEnd: string;

    switch (period) {
      case "jour":
        gradesCutoff = new Date(now); gradesCutoff.setDate(gradesCutoff.getDate() - 1);
        scheduleDateStart = todayStr;
        scheduleDateEnd = tomorrowStr;
        break;
      case "semaine":
        gradesCutoff = new Date(now); gradesCutoff.setDate(gradesCutoff.getDate() - 7);
        const weekEnd = new Date(now); weekEnd.setDate(weekEnd.getDate() + 7);
        scheduleDateStart = todayStr;
        scheduleDateEnd = weekEnd.toISOString().split("T")[0]!;
        break;
      case "semestre":
        gradesCutoff = new Date(now); gradesCutoff.setMonth(gradesCutoff.getMonth() - 6);
        scheduleDateStart = todayStr;
        scheduleDateEnd = new Date(now.getTime() + 30 * 86400000).toISOString().split("T")[0]!;
        break;
    }

    const grades = period === "semestre"
      ? allGrades
      : allGrades.filter((g) => new Date(g.date) >= gradesCutoff);
    const schedule = allSchedule.filter(
      (s) => s.startTime >= scheduleDateStart && s.startTime < scheduleDateEnd
    );
    const homework = allHomework;

    return { grades, schedule, homework };
  }, [period, allGrades, allSchedule, allHomework, activeChild]);

  // Rebuild briefing/stats/insights when period data changes
  useEffect(() => {
    if (!periodData || !activeChild || activeChild.source === "ent") return;
    const { grades, schedule, homework } = periodData;
    setBriefing(buildBriefing(activeChild.firstName, grades, schedule, homework));
    setInsights(extractTextInsights(grades, schedule, homework));
    setStats(extractStats(grades, schedule, homework));
    setLoaded(true);
  }, [periodData, activeChild]);

  useEffect(() => {
    setLoaded(false);
    setBriefing(null);
    setAiSummary(null);
    setInsights([]);
    setStats(null);
    setAllGrades([]);
    setAllSchedule([]);
    setAllHomework([]);
    loadBriefing();
  }, [activeChild]);

  // Generate summary when briefing is ready
  // Priority: Apple Intelligence (iOS 26+) → text generator (everywhere)
  useEffect(() => {
    if (!briefing || aiSummary) return;

    let cancelled = false;
    (async () => {
      // Try Apple Intelligence first
      try {
        if (isMLAvailable() && briefing.llmContext) {
          setAiLoading(true);
          const summary = await generateSummary(
            briefing.llmContext,
            "Tu es l'assistant de nōto., une app pour parents d'élèves. " +
            "Résume les informations scolaires en 2-3 phrases courtes et naturelles en français. " +
            "Sois concis, bienveillant, et mentionne les points importants (devoirs urgents, notes, absences). " +
            "Ne répète pas le nom de l'élève s'il est déjà dans le contexte."
          );
          if (!cancelled && summary) {
            setAiSummary(summary);
            setAiLoading(false);
            return;
          }
        }
      } catch {
        // Apple Intelligence not available — fall through
      }

      // Fallback: text generator (works everywhere)
      if (!cancelled && briefing.items.length > 0) {
        const text = generateTextSummary(briefing);
        if (text) setAiSummary(text);
      }
      if (!cancelled) setAiLoading(false);
    })();
    return () => { cancelled = true; };
  }, [briefing]);

  // Auto-sync on first load if no data (Pronote children only)
  useEffect(() => {
    if (loaded && activeChild && activeChild.source !== "ent" && briefing && briefing.items.length <= 1) {
      sync(activeChild.id).then(() => loadBriefing());
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

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
      refreshControl={
        <RefreshControl
          refreshing={syncing}
          onRefresh={() => {
            if (activeChild.source !== "ent") {
              sync(activeChild.id).then(() => loadBriefing());
            } else {
              loadBriefing();
            }
          }}
          tintColor={theme.accent}
        />
      }
    >
      {/* Greeting */}
      {briefing && (
        <Text style={[styles.greeting, { color: theme.text }]}>
          {briefing.greeting}
        </Text>
      )}

      {/* Loading */}
      {!loaded && (
        <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />
      )}

      {/* Period picker (Pronote only) */}
      {activeChild.source !== "ent" && (
        <View style={styles.periodRow}>
          {(["jour", "semaine", "semestre"] as const).map((p) => (
            <Pressable
              key={p}
              onPress={() => { setPeriod(p); setAiSummary(null); }}
              style={[
                styles.periodChip,
                {
                  backgroundColor: period === p ? theme.accent : "transparent",
                  borderColor: period === p ? theme.accent : theme.border,
                },
              ]}
            >
              <Text style={[
                styles.periodText,
                { color: period === p ? "#FFFFFF" : theme.textSecondary },
              ]}>
                {p.charAt(0).toUpperCase() + p.slice(1)}
              </Text>
            </Pressable>
          ))}
        </View>
      )}

      {/* AI Summary */}
      {(aiSummary || aiLoading) && (
        <View style={[styles.aiCard, { backgroundColor: theme.surfaceElevated, borderColor: theme.border }]}>
          {aiLoading ? (
            <ActivityIndicator size="small" color={theme.accent} />
          ) : (
            <Text style={[styles.aiText, { color: theme.text }]}>{aiSummary}</Text>
          )}
        </View>
      )}

      {/* Stats */}
      {stats && <StatsCard stats={stats} theme={theme} />}

      {/* Insights */}
      {insights.length > 0 && <InsightsCard insights={insights} theme={theme} />}

      {/* Class info */}
      {activeChild.className ? (
        <Text style={[styles.className, { color: theme.textTertiary }]}>
          {activeChild.className}
        </Text>
      ) : null}

      {/* Briefing items */}
      {briefing && briefing.items.length > 0 && (
        <View style={styles.briefingList}>
          {briefing.items.map((item, i) => (
            <BriefingCard key={`${item.type}-${i}`} item={item} theme={theme} onPress={handleBriefingTap} />
          ))}
        </View>
      )}

      {/* Empty state */}
      {loaded && briefing && briefing.items.length === 0 && (
        <View style={styles.emptyBriefing}>
          <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
            Rien de particulier aujourd'hui.
          </Text>
        </View>
      )}

    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  greeting: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.semiBold,
    lineHeight: 24,
    marginBottom: Spacing.xs,
  },
  className: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.medium,
    letterSpacing: 1,
    textTransform: "uppercase",
    marginBottom: Spacing.md,
  },
  periodRow: {
    flexDirection: "row",
    gap: Spacing.xs,
    marginBottom: Spacing.md,
  },
  periodChip: {
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 20,
    borderWidth: 1,
  },
  periodText: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.medium,
  },
  aiCard: {
    padding: Spacing.md,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: Spacing.md,
    minHeight: 40,
    justifyContent: "center",
  },
  aiText: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    lineHeight: 20,
  },
  briefingList: {
    marginTop: Spacing.sm,
  },
  emptyBriefing: {
    justifyContent: "center",
    alignItems: "center",
    paddingTop: Spacing.xxl,
  },

  // Empty state (no child)
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
