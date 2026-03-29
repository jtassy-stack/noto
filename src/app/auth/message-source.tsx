import { View, Text, Pressable, StyleSheet } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { setChildSetting } from "@/lib/database/repository";
import type { MessageSource } from "@/types";

/**
 * Shown after Pronote login for lycée accounts.
 * Lets the parent choose which messaging backend to use:
 * - Pronote discussions only
 * - ENT messages only (Mon Lycée / Zimbra)
 * - Both
 * - Skip (no messaging)
 */
export default function MessageSourceScreen() {
  const theme = useTheme();
  const { childIds, childNames } = useLocalSearchParams<{
    childIds: string;
    childNames: string;
  }>();

  const ids = childIds?.split(",") ?? [];
  const names = childNames?.split(",") ?? [];

  async function pick(source: MessageSource | "skip") {
    if (source !== "skip") {
      for (const id of ids) {
        await setChildSetting(id, "message_source", source);
      }
    }
    router.replace("/");
  }

  const options: Array<{ source: MessageSource | "skip"; label: string; desc: string; color: string }> = [
    {
      source: "pronote",
      label: "Pronote uniquement",
      desc: "Messages et discussions Pronote",
      color: theme.accent,
    },
    {
      source: "ent",
      label: "ENT uniquement",
      desc: "Messagerie Mon Lycée / ENT",
      color: "#1B3A6B",
    },
    {
      source: "both",
      label: "Les deux",
      desc: "Pronote + ENT combinés",
      color: theme.accent,
    },
  ];

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <Text style={[styles.title, { color: theme.text }]}>Messagerie</Text>
      <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
        {names.length === 1
          ? `Quelle messagerie souhaitez-vous utiliser pour ${names[0]} ?`
          : "Quelle messagerie souhaitez-vous utiliser ?"}
      </Text>
      <Text style={[styles.hint, { color: theme.textTertiary }]}>
        Vous pourrez modifier ce choix plus tard dans les réglages.
      </Text>

      <View style={styles.options}>
        {options.map((opt) => (
          <Pressable
            key={opt.source}
            style={({ pressed }) => [
              styles.card,
              {
                backgroundColor: theme.surface,
                borderColor: pressed ? opt.color : theme.border,
              },
            ]}
            onPress={() => pick(opt.source)}
          >
            <View style={styles.cardText}>
              <Text style={[styles.cardLabel, { color: theme.text }]}>{opt.label}</Text>
              <Text style={[styles.cardDesc, { color: theme.textSecondary }]}>{opt.desc}</Text>
            </View>
          </Pressable>
        ))}
      </View>

      <Pressable onPress={() => pick("skip")}>
        <Text style={[styles.skipLink, { color: theme.textTertiary }]}>
          Pas de messagerie pour l'instant
        </Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: Spacing.lg, paddingTop: Spacing.xl },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold },
  subtitle: {
    fontSize: FontSize.md, fontFamily: Fonts.regular,
    marginTop: Spacing.sm, lineHeight: 22,
  },
  hint: {
    fontSize: FontSize.xs, fontFamily: Fonts.regular,
    marginTop: Spacing.xs, lineHeight: 16,
  },
  options: { marginTop: Spacing.xl, gap: Spacing.sm },
  card: {
    borderRadius: BorderRadius.lg, padding: 16, borderWidth: 1,
  },
  cardText: { gap: 2 },
  cardLabel: { fontSize: FontSize.lg - 1, fontFamily: Fonts.semiBold },
  cardDesc: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  skipLink: {
    fontSize: FontSize.sm, fontFamily: Fonts.medium,
    marginTop: Spacing.xl, textAlign: "center",
  },
});
