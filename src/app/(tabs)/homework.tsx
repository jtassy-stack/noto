import { useEffect, useState, useCallback } from "react";
import { View, Text, StyleSheet, ScrollView, ActivityIndicator } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getHomeworkByChild } from "@/lib/database/repository";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { fetchHomeworks, type PcnHomeworkEntry } from "@/lib/ent/pcn-data";
import type { Homework } from "@/types";

// Unified homework item for rendering (covers both Pronote and ENT)
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

export default function HomeworkScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [items, setItems] = useState<HomeworkItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadHomework = useCallback(async () => {
    if (!activeChild) return;

    setLoading(true);
    setError(null);

    try {
      if (activeChild.source === "ent") {
        const creds = await getConversationCredentials();
        if (!creds) {
          setError("Identifiants ENT non trouvés.");
          setItems([]);
          return;
        }
        const hw = await fetchHomeworks(creds);
        setItems(hw.map(pcnToItem));
      } else {
        // Pronote (or other local DB sources)
        const today = new Date().toISOString().split("T")[0]!;
        const hw = await getHomeworkByChild(activeChild.id, today);
        setItems(hw.map(pronoteToItem));
      }
    } catch (e) {
      console.warn("[nōto] Homework load error:", e);
      setError("Impossible de charger les devoirs.");
      setItems([]);
    } finally {
      setLoading(false);
    }
  }, [activeChild]);

  useEffect(() => {
    loadHomework();
  }, [loadHomework]);

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Connectez un compte.
        </Text>
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

  if (error) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          {error}
        </Text>
      </View>
    );
  }

  if (items.length === 0) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Aucun devoir à venir.
        </Text>
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
        const label = d.toLocaleDateString("fr-FR", {
          weekday: "long",
          day: "numeric",
          month: "long",
        });

        return (
          <View key={date} style={styles.dateGroup}>
            <Text style={[styles.dateLabel, { color: theme.textTertiary }]}>
              {label.toUpperCase()}
            </Text>
            {dateItems.map((h) => (
              <View
                key={h.id}
                style={[
                  styles.card,
                  {
                    backgroundColor: theme.surface,
                    borderColor: theme.border,
                    opacity: h.isDone ? 0.5 : 1,
                  },
                ]}
              >
                <View style={styles.cardHeader}>
                  <View
                    style={[
                      styles.dot,
                      { backgroundColor: h.isDone ? theme.textTertiary : theme.accent },
                    ]}
                  />
                  <Text style={[styles.subject, { color: theme.text }]}>
                    {h.subject || "Devoir"}
                  </Text>
                  {h.isDone && (
                    <Text style={[styles.doneBadge, { color: theme.textTertiary }]}>
                      fait
                    </Text>
                  )}
                </View>
                {h.description !== "" && (
                  <Text
                    style={[styles.description, { color: theme.textSecondary }]}
                    numberOfLines={4}
                  >
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

  dateGroup: { marginBottom: Spacing.lg },
  dateLabel: {
    fontSize: 11,
    fontFamily: Fonts.medium,
    letterSpacing: 1.5,
    marginBottom: Spacing.sm,
  },

  card: {
    padding: 14,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: 6,
  },
  cardHeader: {
    flexDirection: "row",
    alignItems: "center",
    gap: Spacing.sm,
    marginBottom: 6,
  },
  dot: { width: 6, height: 6, borderRadius: 3 },
  subject: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, flex: 1 },
  doneBadge: { fontSize: FontSize.xs, fontFamily: Fonts.medium },
  description: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    lineHeight: 20,
    paddingLeft: 14,
  },
});
