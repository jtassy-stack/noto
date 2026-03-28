import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getHomeworkByChild } from "@/lib/database/repository";
import type { Homework } from "@/types";

export default function HomeworkScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [homework, setHomework] = useState<Homework[]>([]);

  useEffect(() => {
    if (!activeChild) return;
    const today = new Date().toISOString().split("T")[0]!;
    getHomeworkByChild(activeChild.id, today).then(setHomework);
  }, [activeChild]);

  if (!activeChild || (activeChild.source === "ent" && !activeChild.hasHomework)) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          {!activeChild ? "Connectez un compte." : "Les devoirs ne sont pas disponibles pour cet enfant.\nConnectez Pronote pour y accéder."}
        </Text>
      </View>
    );
  }

  if (homework.length === 0) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Aucun devoir à venir.
        </Text>
      </View>
    );
  }

  // Group by due date
  const grouped = new Map<string, Homework[]>();
  for (const h of homework) {
    const list = grouped.get(h.dueDate) ?? [];
    list.push(h);
    grouped.set(h.dueDate, list);
  }

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {Array.from(grouped.entries()).map(([date, items]) => {
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
            {items.map((h) => (
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
                    {h.subject}
                  </Text>
                  {h.isDone && (
                    <Text style={[styles.doneBadge, { color: theme.textTertiary }]}>
                      fait
                    </Text>
                  )}
                </View>
                <Text
                  style={[styles.description, { color: theme.textSecondary }]}
                  numberOfLines={4}
                >
                  {h.description}
                </Text>
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
