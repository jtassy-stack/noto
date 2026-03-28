import { useState } from "react";
import {
  View, Text, TextInput, Pressable, StyleSheet,
  ActivityIndicator, KeyboardAvoidingView, Platform, ScrollView,
} from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getEntProvider, ENT_PROVIDERS } from "@/lib/ent/providers";
import { saveMailCredentials, fetchUnreadCount } from "@/lib/ent/mail";
import { saveEntSession } from "@/lib/ent/auth";

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleLogin() {
    if (!email || !password) {
      setError("Tous les champs sont requis.");
      return;
    }

    setLoading(true);
    setError(null);

    try {
      // Test credentials by fetching unread count via IMAP proxy
      const result = await fetchUnreadCount({ email: email.trim(), password });
      console.log("[nōto] IMAP login success! Unread:", result.unseen, "Total:", result.total);

      // Save credentials (encrypted in SecureStore)
      await saveMailCredentials({ email: email.trim(), password });

      // Save ENT session
      await saveEntSession({
        providerId: entProvider.id,
        expiresAt: Date.now() + 365 * 24 * 60 * 60 * 1000, // IMAP doesn't expire
        apiBaseUrl: entProvider.apiBaseUrl,
        useCookieJar: false,
      });

      router.replace("/");
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : "Erreur inconnue";
      setError(message);
      console.warn("[nōto] IMAP login failed:", e);
    } finally {
      setLoading(false);
    }
  }

  return (
    <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === "ios" ? "padding" : "height"}>
      <ScrollView
        style={[styles.container, { backgroundColor: theme.background }]}
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
      >
        <Text style={[styles.title, { color: theme.text }]}>
          {entProvider.icon} {entProvider.name}
        </Text>
        <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
          Connectez votre messagerie {entProvider.name} avec votre adresse e-mail.
        </Text>

        <View style={styles.form}>
          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>Adresse e-mail</Text>
            <TextInput
              style={[styles.input, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
              placeholder="prenom.nom@monlycee.net"
              placeholderTextColor={theme.textTertiary}
              value={email}
              onChangeText={setEmail}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="email-address"
            />
          </View>

          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>Mot de passe</Text>
            <TextInput
              style={[styles.input, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
              placeholder="Votre mot de passe"
              placeholderTextColor={theme.textTertiary}
              value={password}
              onChangeText={setPassword}
              secureTextEntry
            />
          </View>

          {error && <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>}

          <Pressable
            style={({ pressed }) => [styles.button, { backgroundColor: entProvider.color, opacity: pressed || loading ? 0.7 : 1 }]}
            onPress={handleLogin}
            disabled={loading}
          >
            {loading ? (
              <ActivityIndicator color="#FFFFFF" size="small" />
            ) : (
              <Text style={styles.buttonText}>Se connecter</Text>
            )}
          </Pressable>
        </View>

        <Text style={[styles.hint, { color: theme.textTertiary }]}>
          Utilisez la même adresse e-mail que celle affichée dans votre messagerie {entProvider.name}.
          C'est l'adresse de type prenom.nom@monlycee.net.
        </Text>

        <Text style={[styles.privacy, { color: theme.textTertiary }]}>
          🔒 Vos identifiants sont stockés de manière chiffrée sur votre appareil
          et ne transitent que vers le serveur mail de {entProvider.name}.
        </Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.xl },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold },
  subtitle: { fontSize: FontSize.md, fontFamily: Fonts.regular, marginTop: Spacing.sm, lineHeight: 22 },
  form: { marginTop: Spacing.xl, gap: Spacing.md },
  field: { gap: Spacing.xs },
  label: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  input: {
    borderWidth: 1, borderRadius: BorderRadius.md,
    paddingHorizontal: Spacing.md, paddingVertical: 14,
    fontSize: FontSize.md, fontFamily: Fonts.regular,
  },
  error: { fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 18 },
  button: {
    borderRadius: BorderRadius.md, paddingVertical: 16,
    alignItems: "center", marginTop: Spacing.sm,
  },
  buttonText: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  hint: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.xl, lineHeight: 16 },
  privacy: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.lg, textAlign: "center", lineHeight: 16 },
});
