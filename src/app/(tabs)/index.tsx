import { View, Text, StyleSheet, ScrollView } from "react-native";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";

export default function DashboardScreen() {
  const theme = useTheme();

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      <View style={styles.header}>
        <Text style={[styles.brand, { color: theme.text }]}>
          n<Text style={{ color: theme.accent }}>ō</Text>to
          <Text style={{ color: theme.accent }}>.</Text>
        </Text>
        <Text style={[styles.date, { color: theme.textSecondary }]}>
          Vendredi 28 mars
        </Text>
      </View>

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
          Connectez votre compte Pronote, ÉcoleDirecte ou Skolengo pour
          commencer.
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
    paddingTop: Spacing.xxl,
  },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  brand: {
    fontSize: 22,
    fontFamily: Fonts.pixel,
  },
  date: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
  },
  card: {
    borderRadius: 8,
    padding: Spacing.lg,
    marginTop: Spacing.xl,
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
