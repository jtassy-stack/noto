import { View, Text, StyleSheet, ScrollView } from "react-native";
import { Colors, FontSize, Spacing } from "@/constants/theme";

export default function DashboardScreen() {
  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Text style={styles.brand}>nōto.</Text>
      <Text style={styles.tagline}>
        l'essentiel de la scolarité, en un coup d'œil.
      </Text>

      <View style={styles.card}>
        <Text style={styles.cardTitle}>Bienvenue</Text>
        <Text style={styles.cardBody}>
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
    backgroundColor: Colors.background,
  },
  content: {
    padding: Spacing.lg,
    paddingTop: Spacing.xxl,
  },
  brand: {
    fontSize: FontSize.hero,
    fontWeight: "700",
    color: Colors.text,
    letterSpacing: -1,
  },
  tagline: {
    fontSize: FontSize.md,
    color: Colors.textSecondary,
    marginTop: Spacing.xs,
    fontStyle: "italic",
  },
  card: {
    backgroundColor: Colors.surface,
    borderRadius: 12,
    padding: Spacing.lg,
    marginTop: Spacing.xl,
    borderWidth: 1,
    borderColor: Colors.border,
  },
  cardTitle: {
    fontSize: FontSize.lg,
    fontWeight: "600",
    color: Colors.text,
    marginBottom: Spacing.sm,
  },
  cardBody: {
    fontSize: FontSize.md,
    color: Colors.textSecondary,
    lineHeight: 22,
  },
});
