import { useEffect, useState, useCallback } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getHomeworkByChild, setChildSetting } from "@/lib/database/repository";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { fetchHomeworks, fetchSchoolbookForChild, type PcnHomeworkEntry, type SchoolbookWordDetail } from "@/lib/ent/pcn-data";
import { stripHtml } from "@/lib/utils/html";
import type { Homework } from "@/types";

// --- Pronote homework ---

interface HomeworkItem {
  id: string;
  subject: string;
  description: string;
  dueDate: string;
  isDone: boolean;
}

function pronoteToItem(h: Homework): HomeworkItem {
  return { id: h.id, subject: h.subject, description: h.description, dueDate: h.dueDate, isDone: h.isDone };
}

function pcnToItem(h: PcnHomeworkEntry): HomeworkItem {
  return { id: h.id, subject: h.subject, description: h.description, dueDate: h.dueDate, isDone: false };
}

// --- ENT Carnet de liaison ---

function SchoolbookCard({ word, theme }: { word: SchoolbookWordDetail; theme: ReturnType<typeof useTheme> }) {
  const dateStr = word.date
    ? new Date(word.date).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" })
    : "";
  const preview = stripHtml(word.text).slice(0, 120);

  return (
    <Pressable
      style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.border }]}
      onPress={() => {
        router.push({
          pathname: "/detail",
          params: {
            title: word.title,
            from: word.sender,
            date: dateStr,
            type: "schoolbook",
            body: word.text,
          },
        });
      }}
    >
      <View style={styles.cardHeader}>
        <View style={[styles.dot, { backgroundColor: theme.crimson }]} />
        <Text style={[styles.subject, { color: theme.text }]} numberOfLines={2}>
          {word.title}
        </Text>
      </View>
      <Text style={[styles.description, { color: theme.textSecondary }]} numberOfLines={3}>
        {preview}
      </Text>
      <View style={styles.metaRow}>
        <Text style={[styles.meta, { color: theme.textTertiary }]}>{word.sender}</Text>
        <Text style={[styles.meta, { color: theme.textTertiary }]}>{dateStr}</Text>
      </View>
    </Pressable>
  );
}

// --- Screen ---

export default function HomeworkScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [items, setItems] = useState<HomeworkItem[]>([]);
  const [schoolbook, setSchoolbook] = useState<SchoolbookWordDetail[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isEnt = activeChild?.source === "ent";

  const load = useCallback(async () => {
    if (!activeChild) return;

    setLoading(true);
    setError(null);

    try {
      if (isEnt) {
        const creds = await getConversationCredentials();
        if (!creds) { setError("Identifiants ENT non trouvés."); return; }

        // Backfill entUserId if needed
        let entUserId = activeChild.entUserId;
        if (!entUserId) {
          await fetch(`${creds.apiBaseUrl}/auth/login`, {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
            redirect: "follow",
          });
          const res = await fetch(`${creds.apiBaseUrl}/userbook/api/person`, {
            headers: { Accept: "application/json" },
          });
          if (res.ok) {
            const data = await res.json();
            const results = data.result ?? data;
            if (Array.isArray(results)) {
              for (const entry of results) {
                if (String(entry.relatedName ?? "").includes(activeChild.firstName)) {
                  entUserId = String(entry.relatedId);
                  await setChildSetting(activeChild.id, "ent_user_id", entUserId);
                  break;
                }
              }
            }
          }
        }

        // Fetch schoolbook (carnet de liaison)
        if (entUserId) {
          const words = await fetchSchoolbookForChild(creds, entUserId);
          setSchoolbook(words);
        }

        // Also try homework
        const hw = await fetchHomeworks(creds).catch(() => []);
        setItems(hw.map(pcnToItem));
      } else {
        const today = new Date().toISOString().split("T")[0]!;
        const hw = await getHomeworkByChild(activeChild.id, today);
        setItems(hw.map(pronoteToItem));
      }
    } catch (e) {
      console.warn("[nōto] Homework/Carnet load error:", e);
      setError("Impossible de charger.");
    } finally {
      setLoading(false);
    }
  }, [activeChild]);

  useEffect(() => {
    setSchoolbook([]);
    setItems([]);
    load();
  }, [load]);

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Connectez un compte.</Text>
      </View>
    );
  }

  if (loading) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <ActivityIndicator color={theme.accent} />
      </View>
    );
  }

  // --- ENT: Carnet de liaison ---
  if (isEnt) {
    const hasSchoolbook = schoolbook.length > 0;
    const hasHomework = items.length > 0;

    if (!hasSchoolbook && !hasHomework) {
      return (
        <View style={[styles.empty, { backgroundColor: theme.background }]}>
          <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
            {error || "Aucun mot dans le carnet de liaison."}
          </Text>
        </View>
      );
    }

    return (
      <ScrollView
        style={[styles.container, { backgroundColor: theme.background }]}
        contentContainerStyle={styles.content}
      >
        {hasSchoolbook && (
          <>
            <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>
              CARNET DE LIAISON
            </Text>
            {schoolbook.map((word) => (
              <SchoolbookCard key={word.id} word={word} theme={theme} />
            ))}
          </>
        )}

        {hasHomework && (
          <>
            <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: hasSchoolbook ? Spacing.lg : 0 }]}>
              CAHIER DE TEXTES
            </Text>
            {items.map((h) => (
              <View
                key={h.id}
                style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.border }]}
              >
                <View style={styles.cardHeader}>
                  <View style={[styles.dot, { backgroundColor: theme.accent }]} />
                  <Text style={[styles.subject, { color: theme.text }]}>{h.subject || "Devoir"}</Text>
                </View>
                {h.description !== "" && (
                  <Text style={[styles.description, { color: theme.textSecondary }]} numberOfLines={4}>
                    {h.description}
                  </Text>
                )}
              </View>
            ))}
          </>
        )}
      </ScrollView>
    );
  }

  // --- Pronote: Devoirs ---
  if (error) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>{error}</Text>
      </View>
    );
  }

  if (items.length === 0) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Aucun devoir à venir.</Text>
      </View>
    );
  }

  // Group by due date
  const grouped = new Map<string, HomeworkItem[]>();
  for (const h of items) {
    const list = grouped.get(h.dueDate) ?? [];
    list.push(h);
    grouped.set(h.dueDate, list);
  }

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {Array.from(grouped.entries()).map(([date, dateItems]) => {
        const d = new Date(date + "T00:00:00");
        const label = d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });

        return (
          <View key={date} style={styles.dateGroup}>
            <Text style={[styles.dateLabel, { color: theme.textTertiary }]}>{label.toUpperCase()}</Text>
            {dateItems.map((h) => (
              <View
                key={h.id}
                style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.border, opacity: h.isDone ? 0.5 : 1 }]}
              >
                <View style={styles.cardHeader}>
                  <View style={[styles.dot, { backgroundColor: h.isDone ? theme.textTertiary : theme.accent }]} />
                  <Text style={[styles.subject, { color: theme.text }]}>{h.subject || "Devoir"}</Text>
                  {h.isDone && <Text style={[styles.doneBadge, { color: theme.textTertiary }]}>fait</Text>}
                </View>
                {h.description !== "" && (
                  <Text style={[styles.description, { color: theme.textSecondary }]} numberOfLines={4}>
                    {h.description}
                  </Text>
                )}
              </View>
            ))}
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

  sectionLabel: {
    fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5, marginBottom: Spacing.sm,
  },

  dateGroup: { marginBottom: Spacing.lg },
  dateLabel: { fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5, marginBottom: Spacing.sm },

  card: {
    padding: 14, borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: 6,
  },
  cardHeader: {
    flexDirection: "row", alignItems: "center", gap: Spacing.sm, marginBottom: 6,
  },
  dot: { width: 6, height: 6, borderRadius: 3 },
  subject: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, flex: 1 },
  doneBadge: { fontSize: FontSize.xs, fontFamily: Fonts.medium },
  description: {
    fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 20, paddingLeft: 14,
  },
  metaRow: {
    flexDirection: "row", justifyContent: "space-between", paddingLeft: 14, marginTop: 4,
  },
  meta: { fontSize: FontSize.xs, fontFamily: Fonts.mono },
});
