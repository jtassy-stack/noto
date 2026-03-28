import { useState } from "react";
import { View, Text, Pressable, StyleSheet, ActivityIndicator } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { loginWithEnt } from "@/lib/ent/auth";
import { getEntProvider, ENT_PROVIDERS } from "@/lib/ent/providers";

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleLogin() {
    setLoading(true);
    setError(null);

    try {
      await loginWithEnt(entProvider);
      console.log("[nōto] ENT login successful for", entProvider.name);
      router.replace("/");
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : "Erreur inconnue";
      if (message.includes("cancelled") || message.includes("dismiss")) {
        // User dismissed the browser
        setError(null);
      } else {
        setError(`Connexion échouée : ${message}`);
        console.warn("[nōto] ENT login failed:", e);
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <Text style={[styles.title, { color: theme.text }]}>
        {entProvider.icon} {entProvider.name}
      </Text>
      <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
        Connectez-vous à votre espace {entProvider.name} pour accéder à
        Pronote et à la messagerie.
      </Text>

      {error && (
        <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>
      )}

      <Pressable
        style={({ pressed }) => [
          styles.button,
          {
            backgroundColor: entProvider.color,
            opacity: pressed || loading ? 0.7 : 1,
          },
        ]}
        onPress={handleLogin}
        disabled={loading}
      >
        {loading ? (
          <ActivityIndicator color="#FFFFFF" size="small" />
        ) : (
          <Text style={styles.buttonText}>
            Se connecter via {entProvider.name}
          </Text>
        )}
      </Pressable>

      <View style={[styles.infoCard, { backgroundColor: theme.surface, borderColor: theme.border }]}>
        <Text style={[styles.infoTitle, { color: theme.text }]}>
          Comment ça marche ?
        </Text>
        <Text style={[styles.infoBody, { color: theme.textSecondary }]}>
          Un navigateur s'ouvrira pour vous connecter sur le site officiel
          de {entProvider.name}. Vos identifiants ne sont jamais partagés
          avec nōto.{"\n\n"}
          Une fois connecté, vous aurez accès à :{"\n"}
          • Notes, emploi du temps et devoirs (Pronote){"\n"}
          • Messagerie de l'établissement
        </Text>
      </View>

      <Text style={[styles.hint, { color: theme.textTertiary }]}>
        🔒 Connexion sécurisée via OAuth2 ({entProvider.region}).
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
  error: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    marginTop: Spacing.md,
  },
  button: {
    borderRadius: BorderRadius.md,
    paddingVertical: 16,
    alignItems: "center",
    justifyContent: "center",
    marginTop: Spacing.xl,
  },
  buttonText: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.semiBold,
    color: "#FFFFFF",
  },
  infoCard: {
    marginTop: Spacing.xl,
    padding: Spacing.md,
    borderRadius: BorderRadius.lg,
    borderWidth: 1,
    gap: Spacing.xs,
  },
  infoTitle: {
    fontSize: FontSize.md,
    fontFamily: Fonts.semiBold,
  },
  infoBody: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    lineHeight: 20,
  },
  hint: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
    marginTop: Spacing.xl,
    textAlign: "center",
    lineHeight: 16,
  },
});
