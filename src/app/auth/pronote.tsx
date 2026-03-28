import { useState } from "react";
import {
  View,
  Text,
  TextInput,
  Pressable,
  StyleSheet,
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  Alert,
} from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import {
  authenticateWithCredentials,
  mapChildren,
} from "@/lib/pronote/client";
import { saveAccount, saveChildren } from "@/lib/database/repository";

export default function PronoteLoginScreen() {
  const theme = useTheme();

  const [instanceUrl, setInstanceUrl] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleLogin() {
    if (!instanceUrl || !username || !password) {
      setError("Tous les champs sont requis.");
      return;
    }

    setLoading(true);
    setError(null);

    try {
      const { session } = await authenticateWithCredentials(
        instanceUrl.trim(),
        username.trim(),
        password
      );

      const children = mapChildren(session);

      // Save account to SQLite
      await saveAccount({
        id: session.information.id.toString(),
        provider: "pronote",
        displayName: session.user.name,
        instanceUrl: instanceUrl.trim(),
        createdAt: Date.now(),
      });

      // Save children to SQLite
      await saveChildren(children);

      router.replace("/");
    } catch (e: unknown) {
      const message =
        e instanceof Error ? e.message : "Erreur de connexion inconnue";

      if (message.includes("BadCredentials")) {
        setError("Identifiants incorrects. Vérifiez votre nom d'utilisateur et mot de passe.");
      } else if (message.includes("AccountDisabled")) {
        setError("Ce compte est désactivé sur Pronote.");
      } else if (message.includes("SuspendedIP")) {
        setError("Trop de tentatives. Réessayez dans quelques minutes.");
      } else {
        setError(`Erreur : ${message}`);
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <KeyboardAvoidingView
      style={{ flex: 1 }}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
    >
      <ScrollView
        style={[styles.container, { backgroundColor: theme.background }]}
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
      >
        <Text style={[styles.title, { color: theme.text }]}>Pronote</Text>
        <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
          Connectez-vous avec votre compte parent Pronote.
        </Text>

        <View style={styles.form}>
          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>
              URL de l'instance
            </Text>
            <TextInput
              style={[
                styles.input,
                {
                  backgroundColor: theme.surface,
                  color: theme.text,
                  borderColor: theme.border,
                },
              ]}
              placeholder="https://pronote.votre-college.fr"
              placeholderTextColor={theme.textTertiary}
              value={instanceUrl}
              onChangeText={setInstanceUrl}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
            />
          </View>

          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>
              Identifiant
            </Text>
            <TextInput
              style={[
                styles.input,
                {
                  backgroundColor: theme.surface,
                  color: theme.text,
                  borderColor: theme.border,
                },
              ]}
              placeholder="Votre identifiant parent"
              placeholderTextColor={theme.textTertiary}
              value={username}
              onChangeText={setUsername}
              autoCapitalize="none"
              autoCorrect={false}
            />
          </View>

          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>
              Mot de passe
            </Text>
            <TextInput
              style={[
                styles.input,
                {
                  backgroundColor: theme.surface,
                  color: theme.text,
                  borderColor: theme.border,
                },
              ]}
              placeholder="Votre mot de passe"
              placeholderTextColor={theme.textTertiary}
              value={password}
              onChangeText={setPassword}
              secureTextEntry
            />
          </View>

          {error && (
            <Text style={[styles.error, { color: theme.crimson }]}>
              {error}
            </Text>
          )}

          <Pressable
            style={({ pressed }) => [
              styles.button,
              {
                backgroundColor: theme.accent,
                opacity: pressed || loading ? 0.7 : 1,
              },
            ]}
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
          L'URL Pronote se trouve dans la barre d'adresse de votre navigateur
          quand vous vous connectez à Pronote.
        </Text>

        <Text style={[styles.privacy, { color: theme.textTertiary }]}>
          🔒 Vos identifiants sont stockés uniquement sur cet appareil.
        </Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  content: {
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
  form: {
    marginTop: Spacing.xl,
    gap: Spacing.md,
  },
  field: {
    gap: Spacing.xs,
  },
  label: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.medium,
  },
  input: {
    borderWidth: 1,
    borderRadius: BorderRadius.md,
    paddingHorizontal: Spacing.md,
    paddingVertical: 14,
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
  },
  error: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    lineHeight: 18,
  },
  button: {
    borderRadius: BorderRadius.md,
    paddingVertical: 16,
    alignItems: "center",
    justifyContent: "center",
    marginTop: Spacing.sm,
  },
  buttonText: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.semiBold,
    color: "#FFFFFF",
  },
  hint: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
    marginTop: Spacing.xl,
    lineHeight: 16,
  },
  privacy: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
    marginTop: Spacing.lg,
    textAlign: "center",
  },
});
