import { useEffect, useState } from "react";
import { View, Text, ScrollView, Pressable, StyleSheet, Alert } from "react-native";
import { router } from "expo-router";
import { Plus, ChevronRight } from "lucide-react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getChildren, getChildSetting, setChildSetting, getAccounts, deleteAccount } from "@/lib/database/repository";
import type { Child, MessageSource, Account } from "@/types";

const MESSAGE_SOURCE_LABELS: Record<MessageSource, string> = {
  pronote: "Pronote",
  ent: "ENT",
  both: "Pronote + ENT",
};

export default function SettingsScreen() {
  const theme = useTheme();
  const [children, setChildren] = useState<Child[]>([]);
  const [accounts, setAccounts] = useState<Account[]>([]);

  useEffect(() => {
    async function load() {
      const [kids, accts] = await Promise.all([getChildren(), getAccounts()]);
      setChildren(kids);
      setAccounts(accts);
    }
    load();
  }, []);

  async function cycleMessageSource(child: Child) {
    const order: MessageSource[] = ["pronote", "ent", "both"];
    const current = child.messageSource;
    const idx = current ? order.indexOf(current) : -1;
    const next = order[(idx + 1) % order.length]!;

    await setChildSetting(child.id, "message_source", next);

    // Update local state
    setChildren((prev) =>
      prev.map((c) => (c.id === child.id ? { ...c, messageSource: next } : c))
    );
  }

  function confirmDeleteAccount(account: Account) {
    Alert.alert(
      "Supprimer le compte",
      `Supprimer le compte ${account.displayName} et toutes ses données ?`,
      [
        { text: "Annuler", style: "cancel" },
        {
          text: "Supprimer",
          style: "destructive",
          onPress: async () => {
            await deleteAccount(account.id);
            setAccounts((prev) => prev.filter((a) => a.id !== account.id));
            setChildren((prev) => prev.filter((c) => c.accountId !== account.id));
          },
        },
      ]
    );
  }

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      <Text style={[styles.title, { color: theme.text }]}>Réglages</Text>

      {/* Add account */}
      <Pressable
        style={({ pressed }) => [
          styles.row,
          { backgroundColor: theme.surface, borderColor: pressed ? theme.accent : theme.border },
        ]}
        onPress={() => router.push("/auth/")}
      >
        <Plus size={18} color={theme.accent} strokeWidth={2} />
        <Text style={[styles.rowLabel, { color: theme.accent }]}>Connecter un compte</Text>
      </Pressable>

      {/* Accounts */}
      {accounts.length > 0 && (
        <>
          <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>COMPTES</Text>
          {accounts.map((acct) => (
            <Pressable
              key={acct.id}
              style={[styles.row, { backgroundColor: theme.surface, borderColor: theme.border }]}
              onLongPress={() => confirmDeleteAccount(acct)}
            >
              <View style={styles.rowContent}>
                <Text style={[styles.rowLabel, { color: theme.text }]}>{acct.displayName}</Text>
                <Text style={[styles.rowSub, { color: theme.textTertiary }]}>
                  {acct.provider === "pronote" ? "Pronote" : acct.provider}
                </Text>
              </View>
            </Pressable>
          ))}
          <Text style={[styles.hint, { color: theme.textTertiary }]}>
            Appui long pour supprimer un compte.
          </Text>
        </>
      )}

      {/* Per-child settings */}
      {children.length > 0 && (
        <>
          <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>ENFANTS</Text>
          {children.map((child) => (
            <View
              key={child.id}
              style={[styles.childCard, { backgroundColor: theme.surface, borderColor: theme.border }]}
            >
              <Text style={[styles.childName, { color: theme.text }]}>
                {child.firstName} {child.lastName}
              </Text>
              <Text style={[styles.childClass, { color: theme.textTertiary }]}>
                {child.className}
              </Text>

              {/* Message source — only for Pronote children */}
              {child.source === "pronote" && (
                <Pressable
                  style={[styles.settingRow, { borderTopColor: theme.border }]}
                  onPress={() => cycleMessageSource(child)}
                >
                  <Text style={[styles.settingLabel, { color: theme.textSecondary }]}>Messagerie</Text>
                  <View style={styles.settingValue}>
                    <Text style={[styles.settingValueText, { color: theme.accent }]}>
                      {child.messageSource ? MESSAGE_SOURCE_LABELS[child.messageSource] : "Non configuré"}
                    </Text>
                    <ChevronRight size={14} color={theme.textTertiary} strokeWidth={2} />
                  </View>
                </Pressable>
              )}
            </View>
          ))}
        </>
      )}

      {/* App info */}
      <Text style={[styles.version, { color: theme.textTertiary }]}>
        nōto. v0.1.0
      </Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.xl, paddingBottom: Spacing.xxl },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold, marginBottom: Spacing.lg },
  sectionLabel: {
    fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5,
    marginTop: Spacing.xl, marginBottom: Spacing.sm,
  },
  row: {
    flexDirection: "row", alignItems: "center",
    borderRadius: BorderRadius.lg, padding: 14, borderWidth: 1,
    gap: Spacing.sm, marginBottom: Spacing.xs,
  },
  rowContent: { flex: 1, gap: 2 },
  rowLabel: { fontSize: FontSize.md, fontFamily: Fonts.medium },
  rowSub: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  hint: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.xs },
  childCard: {
    borderRadius: BorderRadius.lg, borderWidth: 1,
    padding: 14, marginBottom: Spacing.sm,
  },
  childName: { fontSize: FontSize.md, fontFamily: Fonts.semiBold },
  childClass: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: 2 },
  settingRow: {
    flexDirection: "row", justifyContent: "space-between", alignItems: "center",
    marginTop: Spacing.sm, paddingTop: Spacing.sm, borderTopWidth: StyleSheet.hairlineWidth,
  },
  settingLabel: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  settingValue: { flexDirection: "row", alignItems: "center", gap: 4 },
  settingValueText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  version: {
    fontSize: FontSize.xs, fontFamily: Fonts.mono,
    textAlign: "center", marginTop: Spacing.xxl,
  },
});
