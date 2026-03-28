import { View, Text, StyleSheet, Pressable } from "react-native";
import { Colors, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import type { Provider } from "@/types";

const PROVIDERS: { key: Provider; label: string; description: string }[] = [
  {
    key: "pronote",
    label: "Pronote",
    description: "Collèges et lycées publics",
  },
  {
    key: "ecoledirecte",
    label: "ÉcoleDirecte",
    description: "Établissements privés",
  },
  {
    key: "skolengo",
    label: "Skolengo",
    description: "Régions Grand Est, Île-de-France...",
  },
];

export default function AuthScreen() {
  const handleSelect = (_provider: Provider) => {
    // TODO: navigate to provider-specific login form
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Connecter un compte</Text>
      <Text style={styles.subtitle}>
        Choisissez le service utilisé par l'établissement de votre enfant.
      </Text>

      <View style={styles.providers}>
        {PROVIDERS.map((p) => (
          <Pressable
            key={p.key}
            style={({ pressed }) => [
              styles.providerCard,
              pressed && styles.providerCardPressed,
            ]}
            onPress={() => handleSelect(p.key)}
          >
            <Text style={styles.providerLabel}>{p.label}</Text>
            <Text style={styles.providerDesc}>{p.description}</Text>
          </Pressable>
        ))}
      </View>

      <Text style={styles.privacy}>
        🔒 Vos identifiants sont stockés uniquement sur votre téléphone.
        Aucune donnée scolaire ne quitte l'appareil.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Colors.background,
    padding: Spacing.lg,
    paddingTop: Spacing.xl,
  },
  title: {
    fontSize: FontSize.xl,
    fontWeight: "700",
    color: Colors.text,
  },
  subtitle: {
    fontSize: FontSize.md,
    color: Colors.textSecondary,
    marginTop: Spacing.sm,
    lineHeight: 22,
  },
  providers: {
    marginTop: Spacing.xl,
    gap: Spacing.md,
  },
  providerCard: {
    backgroundColor: Colors.surface,
    borderRadius: BorderRadius.md,
    padding: Spacing.lg,
    borderWidth: 1,
    borderColor: Colors.border,
  },
  providerCardPressed: {
    backgroundColor: Colors.surfaceElevated,
    borderColor: Colors.accent,
  },
  providerLabel: {
    fontSize: FontSize.lg,
    fontWeight: "600",
    color: Colors.text,
  },
  providerDesc: {
    fontSize: FontSize.sm,
    color: Colors.textSecondary,
    marginTop: Spacing.xs,
  },
  privacy: {
    fontSize: FontSize.xs,
    color: Colors.textTertiary,
    marginTop: Spacing.xxl,
    textAlign: "center",
    lineHeight: 18,
  },
});
