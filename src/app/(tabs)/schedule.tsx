import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getScheduleByChild } from "@/lib/database/repository";
import { EntPhotoGallery } from "@/components/ent/PhotoGallery";
import type { ScheduleEntry } from "@/types";

const DAY_LABELS = ["D", "L", "M", "Me", "J", "V", "S"];

function getDateForOffset(offset: number): Date {
  const d = new Date();
  d.setDate(d.getDate() + offset);
  d.setHours(0, 0, 0, 0);
  return d;
}

export default function ScheduleScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [dayOffset, setDayOffset] = useState(0);
  const [schedule, setSchedule] = useState<ScheduleEntry[]>([]);

  useEffect(() => {
    if (!activeChild || activeChild.source === "ent") return;

    const day = getDateForOffset(dayOffset);
    const nextDay = getDateForOffset(dayOffset + 1);

    getScheduleByChild(activeChild.id, day.toISOString(), nextDay.toISOString()).then(setSchedule);
  }, [activeChild, dayOffset]);

  // ENT child → photo gallery
  if (activeChild?.source === "ent") {
    return <EntPhotoGallery />;
  }

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Connectez un compte.</Text>
      </View>
    );
  }

  const dayTabs = [-2, -1, 0, 1, 2].map((offset) => {
    const d = getDateForOffset(offset);
    return { offset, label: DAY_LABELS[d.getDay()]!, date: d.getDate(), isToday: offset === 0 };
  });

  const selectedDate = getDateForOffset(dayOffset);
  const dateStr = selectedDate.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });

  return (
    <ScrollView style={[styles.container, { backgroundColor: theme.background }]} contentContainerStyle={styles.content}>
      <View style={styles.dayTabs}>
        {dayTabs.map((d) => {
          const active = d.offset === dayOffset;
          return (
            <Pressable
              key={d.offset}
              onPress={() => setDayOffset(d.offset)}
              style={[styles.dayTab, { backgroundColor: active ? theme.accent : theme.surfaceElevated, borderColor: active ? theme.accent : theme.border }]}
            >
              <Text style={[styles.dayLabel, { color: active ? "#FFFFFF" : theme.textSecondary }]}>{d.label}</Text>
              <Text style={[styles.dayDate, { color: active ? "#FFFFFF" : theme.text, fontFamily: active ? Fonts.bold : Fonts.regular }]}>{d.date}</Text>
            </Pressable>
          );
        })}
      </View>

      <Text style={[styles.dateLabel, { color: theme.textSecondary }]}>{dateStr}</Text>

      {schedule.length === 0 && (
        <Text style={[styles.emptyText, { color: theme.textTertiary, marginTop: Spacing.xl }]}>Aucun cours ce jour.</Text>
      )}

      {schedule.map((s) => {
        const startTime = new Date(s.startTime).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
        const endTime = new Date(s.endTime).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });

        return (
          <View key={s.id} style={styles.slot}>
            <View style={styles.timeCol}>
              <Text style={[styles.startTime, { color: theme.accent }]}>{startTime}</Text>
              <Text style={[styles.endTime, { color: theme.textTertiary }]}>{endTime}</Text>
            </View>
            <View style={[styles.divider, { backgroundColor: s.isCancelled ? theme.crimson : theme.accent, opacity: s.isCancelled ? 0.4 : 0.3 }]} />
            <View style={styles.slotContent}>
              <Text style={[styles.slotSubject, { color: s.isCancelled ? theme.textTertiary : theme.text, textDecorationLine: s.isCancelled ? "line-through" : "none" }]}>{s.subject}</Text>
              <Text style={[styles.slotMeta, { color: theme.textTertiary }]}>
                {[s.teacher, s.room].filter(Boolean).join(" · ")}
              </Text>
              {s.isCancelled && (
                <View style={[styles.cancelBadge, { backgroundColor: theme.crimson + "1F" }]}>
                  <Text style={[styles.cancelText, { color: theme.crimson }]}>Annulé</Text>
                </View>
              )}
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
  dayTabs: { flexDirection: "row", gap: 4, marginBottom: Spacing.md },
  dayTab: { flex: 1, alignItems: "center", paddingVertical: 10, borderRadius: BorderRadius.md, borderWidth: 1, gap: 2 },
  dayLabel: { fontSize: FontSize.xs, fontFamily: Fonts.medium },
  dayDate: { fontSize: FontSize.lg },
  dateLabel: { fontSize: FontSize.sm, fontFamily: Fonts.regular, marginBottom: Spacing.md, textTransform: "capitalize" },
  slot: { flexDirection: "row", paddingVertical: 14, gap: 14 },
  timeCol: { width: 46, gap: 2 },
  startTime: { fontSize: 13, fontFamily: Fonts.mono },
  endTime: { fontSize: FontSize.xs, fontFamily: Fonts.mono },
  divider: { width: 2, borderRadius: 1, alignSelf: "stretch" },
  slotContent: { flex: 1, gap: 3 },
  slotSubject: { fontSize: FontSize.md, fontFamily: Fonts.medium },
  slotMeta: { fontSize: 11, fontFamily: Fonts.regular },
  cancelBadge: { alignSelf: "flex-start", paddingHorizontal: 6, paddingVertical: 2, borderRadius: 4, marginTop: 2 },
  cancelText: { fontSize: 10, fontFamily: Fonts.semiBold },
});
