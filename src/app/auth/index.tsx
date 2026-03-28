import { View, Text, StyleSheet, Pressable } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import type { Provider } from "@/types";

const PROVIDERS: { key: Provider; label: string; description: string; icon: string }[] = [
  { key: "pronote", label: "Pronote", description: "Collèges et lycées publics", icon: "P" },
  { key: "ecoledirecte", label: "ÉcoleDirecte", description: "Établissements privés", icon: "E" },
  { key: "skolengo", label: "Skolengo", description: "Régions Grand Est, Île-de-France...", icon: "S" },
];

export default function AuthScreen() {
  const theme = useTheme();

  const handleSelect = (_provider: Provider) => {
    // TODO: navigate to provider-specific login form
  };

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <Text style={[styles.title, { color: theme.text }]}>
        Connecter un compte
      </Text>
      <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
        Choisissez le service utilisé par l'établissement de votre enfant.
      </Text>

      <View style={styles.providers}>
        {PROVIDERS.map((p) => (
          <Pressable
            key={p.key}
            style={({ pressed }) => [
              styles.providerCard,
              {
                backgroundColor: theme.surface,
                borderColor: pressed ? theme.accent : theme.border,
              },
            ]}
            onPress={() => handleSelect(p.key)}
          >
            <View
              style={[
                styles.iconBox,
                { backgroundColor: theme.surfaceElevated },
              ]}
            >
              <Text
                style={[styles.iconText, { color: theme.accent }]}
              >
                {p.icon}
              </Text>
            </View>
            <View style={styles.textBlock}>
              <Text style={[styles.providerLabel, { color: theme.text }]}>
                {p.label}
              </Text>
              <Text
                style={[styles.providerDesc, { color: theme.textSecondary }]}
              >
                {p.description}
              </Text>
            </View>
          </Pressable>
        ))}
      </View>

      <Text style={[styles.privacy, { color: theme.textTertiary }]}>
        🔒 Vos identifiants sont stockés uniquement sur votre téléphone.
        Aucune donnée scolaire ne quitte l'appareil.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: Spacing.lg,
    paddingTop: Spacing.xl,
  },
  title: {
    fontSize: FontSize.xxl,
    fontFamily: Fonts.bold,
  },
  subtitle: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    marginTop: Spacing.sm,
    lineHeight: 22,
  },
  providers: {
    marginTop: Spacing.xl,
    gap: Spacing.sm,
  },
  providerCard: {
    flexDirection: "row",
    alignItems: "center",
    borderRadius: BorderRadius.lg,
    padding: 18,
    borderWidth: 1,
    gap: Spacing.md,
  },
  iconBox: {
    width: 40,
    height: 40,
    borderRadius: BorderRadius.lg,
    justifyContent: "center",
    alignItems: "center",
  },
  iconText: {
    fontSize: 18,
    fontFamily: Fonts.monoBold,
  },
  textBlock: {
    flex: 1,
    gap: 3,
  },
  providerLabel: {
    fontSize: FontSize.lg - 1,
    fontFamily: Fonts.semiBold,
  },
  providerDesc: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
  },
  privacy: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    marginTop: Spacing.xxl,
    textAlign: "center",
    lineHeight: 18,
  },
});
