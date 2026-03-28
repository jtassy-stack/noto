import { useEffect, useState } from "react";
import { View, Text, Pressable, StyleSheet, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useEntAuth, exchangeCodeForTokens } from "@/lib/ent/auth";

export default function EntLoginScreen() {
  const theme = useTheme();
  const { request, response, promptAsync, redirectUri } = useEntAuth();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (response?.type === "success" && response.params.code) {
      handleCodeExchange(response.params.code);
    } else if (response?.type === "error") {
      setError("Connexion annulée ou échouée.");
      setLoading(false);
    }
  }, [response]);

  async function handleCodeExchange(code: string) {
    setLoading(true);
    setError(null);

    try {
      if (!request?.codeVerifier) {
        throw new Error("Code verifier missing");
      }

      await exchangeCodeForTokens(code, request.codeVerifier, redirectUri);
      console.log("[nōto] ENT auth successful");
      router.replace("/");
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : "Erreur inconnue";
      setError(`Connexion échouée : ${message}`);
      console.warn("[nōto] ENT token exchange failed:", e);
    } finally {
      setLoading(false);
    }
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <Text style={[styles.title, { color: theme.text }]}>
        Mon Lycée
      </Text>
      <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
        Connectez-vous à votre espace Mon Lycée (ENT Île-de-France) pour
        accéder à la messagerie.
      </Text>

      {error && (
        <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>
      )}

      <Pressable
        style={({ pressed }) => [
          styles.button,
          {
            backgroundColor: "#1B3A6B",
            opacity: pressed || loading || !request ? 0.7 : 1,
          },
        ]}
        onPress={() => {
          setLoading(true);
          setError(null);
          promptAsync();
        }}
        disabled={!request || loading}
      >
        {loading ? (
          <ActivityIndicator color="#FFFFFF" size="small" />
        ) : (
          <Text style={styles.buttonText}>Se connecter via Mon Lycée</Text>
        )}
      </Pressable>

      <View style={[styles.infoCard, { backgroundColor: theme.surface, borderColor: theme.border }]}>
        <Text style={[styles.infoTitle, { color: theme.text }]}>
          Comment ça marche ?
        </Text>
        <Text style={[styles.infoBody, { color: theme.textSecondary }]}>
          Un navigateur s'ouvrira pour vous connecter sur le site officiel
          Mon Lycée. Vos identifiants ne sont jamais partagés avec nōto.
        </Text>
      </View>

      <Text style={[styles.hint, { color: theme.textTertiary }]}>
        🔒 Connexion sécurisée via le protocole OAuth2 officiel de la Région Île-de-France.
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
