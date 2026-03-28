import { View, Text, StyleSheet, ScrollView } from "react-native";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";

export default function DashboardScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Connectez un compte pour commencer.
        </Text>
      </View>
    );
  }

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      <Text style={[styles.greeting, { color: theme.textSecondary }]}>
        {activeChild.className}
      </Text>

      <View
        style={[
          styles.card,
          { backgroundColor: theme.surface, borderColor: theme.border },
        ]}
      >
        <Text style={[styles.cardTitle, { color: theme.text }]}>
          Bienvenue
        </Text>
        <Text style={[styles.cardBody, { color: theme.textSecondary }]}>
          Les données de {activeChild.firstName} apparaîtront ici une fois le
          compte Pronote ou ÉcoleDirecte connecté.
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  content: {
    padding: Spacing.lg,
    paddingTop: Spacing.md,
  },
  greeting: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.medium,
    letterSpacing: 1,
    textTransform: "uppercase",
  },
  card: {
    borderRadius: 8,
    padding: Spacing.lg,
    marginTop: Spacing.md,
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
  empty: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    padding: Spacing.lg,
  },
  emptyText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    textAlign: "center",
  },
});
