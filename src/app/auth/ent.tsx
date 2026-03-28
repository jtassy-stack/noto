import { useState } from "react";
import { View, Text, TextInput, Pressable, StyleSheet, ActivityIndicator, KeyboardAvoidingView, Platform, ScrollView } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getEntProvider, ENT_PROVIDERS } from "@/lib/ent/providers";
import { saveMailCredentials, fetchUnreadCount } from "@/lib/ent/mail";
import { loginToENT, saveConversationCredentials } from "@/lib/ent/conversation";
import { saveEntSession } from "@/lib/ent/auth";

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const isIMAP = entProvider.messagingType === "zimbra";
  const emailDomain = isIMAP ? "@monlycee.net" : "";

  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleLogin() {
    if (!username || !password) {
      setError("Tous les champs sont requis.");
      return;
    }

    setLoading(true);
    setError(null);

    try {
      if (isIMAP) {
        // Mon Lycée: IMAP via proxy
        const fullEmail = username.trim().includes("@")
          ? username.trim()
          : `${username.trim()}@monlycee.net`;

        const result = await fetchUnreadCount({ email: fullEmail, password });
        console.log("[nōto] IMAP OK! Unread:", result.unseen);
        await saveMailCredentials({ email: fullEmail, password });
      } else {
        // PCN: direct ENTCore Conversation API
        const { sessionCookie } = await loginToENT(entProvider, username.trim(), password);
        console.log("[nōto] PCN login OK!");
        await saveConversationCredentials({
          email: username.trim(),
          password,
          apiBaseUrl: entProvider.apiBaseUrl,
          sessionCookie,
        });
      }

      await saveEntSession({
        providerId: entProvider.id,
        expiresAt: Date.now() + 365 * 24 * 60 * 60 * 1000,
        apiBaseUrl: entProvider.apiBaseUrl,
        useCookieJar: false,
      });

      if (router.canDismiss()) router.dismissAll();
      router.replace("/");
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "Erreur inconnue";
      setError(msg);
      console.warn("[nōto] Login failed:", e);
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
          {entProvider.icon} Messagerie {entProvider.name}
        </Text>
        <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
          Connectez votre messagerie avec vos identifiants {entProvider.name}.
        </Text>

        <View style={styles.form}>
          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>Identifiant</Text>
            {emailDomain ? (
              <View style={styles.inputRow}>
                <TextInput
                  style={[styles.input, styles.inputFlex, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
                  placeholder="prenom.nom"
                  placeholderTextColor={theme.textTertiary}
                  value={username}
                  onChangeText={setUsername}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
                <Text style={[styles.suffix, { color: theme.textTertiary }]}>{emailDomain}</Text>
              </View>
            ) : (
              <TextInput
                style={[styles.input, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
                placeholder="Votre identifiant"
                placeholderTextColor={theme.textTertiary}
                value={username}
                onChangeText={setUsername}
                autoCapitalize="none"
                autoCorrect={false}
              />
            )}
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
              <Text style={styles.buttonText}>Connecter la messagerie</Text>
            )}
          </Pressable>
        </View>

        <Text style={[styles.privacy, { color: theme.textTertiary }]}>
          🔒 Vos identifiants sont chiffrés sur votre appareil.
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
  inputRow: { flexDirection: "row", alignItems: "center", gap: Spacing.xs },
  input: { borderWidth: 1, borderRadius: BorderRadius.md, paddingHorizontal: Spacing.md, paddingVertical: 14, fontSize: FontSize.md, fontFamily: Fonts.regular },
  inputFlex: { flex: 1 },
  suffix: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  error: { fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 18 },
  button: { borderRadius: BorderRadius.md, paddingVertical: 16, alignItems: "center", marginTop: Spacing.sm },
  buttonText: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  privacy: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.xxl, textAlign: "center", lineHeight: 16 },
});
