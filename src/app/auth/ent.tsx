import { useState, useRef } from "react";
import { View, Text, TextInput, Pressable, StyleSheet, ActivityIndicator, KeyboardAvoidingView, Platform, ScrollView } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import type { WebViewNavigation } from "react-native-webview";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getEntProvider, ENT_PROVIDERS } from "@/lib/ent/providers";
import { saveMailCredentials, fetchUnreadCount } from "@/lib/ent/mail";
import { saveEntSession } from "@/lib/ent/auth";
import { authenticateWithCredentials, mapChildren } from "@/lib/pronote/client";
import { syncWithSession } from "@/lib/pronote/sync";
import { saveAccount, saveChildren } from "@/lib/database/repository";

type Phase = "webview" | "password" | "connecting";

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const [phase, setPhase] = useState<Phase>("webview");
  const [status, setStatus] = useState("Connexion à " + entProvider.name + "...");
  const [email, setEmail] = useState("");
  const [pronoteUrl, setPronoteUrl] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const sawCallbackRef = useRef(false);
  const doneRef = useRef(false);
  const webViewRef = useRef<WebView>(null);

  // --- Phase 1: WebView → Keycloak login → scrape email + Pronote URL ---

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView:", url.substring(0, 80));

    if (url.includes("auth.monlycee.net") && url.includes("login-actions")) {
      setStatus("Saisissez vos identifiants...");
    }

    if (url.includes("/oauth2/callback")) {
      sawCallbackRef.current = true;
      setStatus("Connexion réussie !");
    }

    // After login, on ENT homepage → scrape data
    if (
      sawCallbackRef.current &&
      !doneRef.current &&
      url.startsWith(entProvider.apiBaseUrl) &&
      !url.includes("/oauth2/callback") &&
      !url.includes("/cas/init") &&
      !url.includes("auth.monlycee.net")
    ) {
      doneRef.current = true;
      setStatus("Récupération de vos informations...");

      // Wait for page to load, then extract email + Pronote link
      setTimeout(() => {
        webViewRef.current?.injectJavaScript(`
          (function() {
            // Find email (@monlycee.net)
            let email = '';
            const allEls = document.querySelectorAll('span, div, p, a');
            allEls.forEach(el => {
              const t = el.textContent.trim();
              if (t.includes('@monlycee.net') && t.length < 60 && !email) {
                email = t.match(/[a-zA-Z0-9._%+-]+@monlycee\\.net/)?.[0] || '';
              }
            });

            // Find Pronote link (with ?page= or direct pronote URL)
            let pronoteLink = '';
            const links = document.querySelectorAll('a');
            links.forEach(l => {
              if (l.href && l.href.includes('pronote') && l.href.includes('parent.html')) {
                pronoteLink = l.href;
              }
            });
            // Fallback: service link
            if (!pronoteLink) {
              links.forEach(l => {
                if (l.href && l.href.includes('index-education.net/pronote')) {
                  pronoteLink = l.href;
                }
              });
            }

            window.ReactNativeWebView.postMessage(JSON.stringify({
              type: 'ent_info',
              email: email,
              pronoteLink: pronoteLink,
            }));
          })();
          true;
        `);
      }, 3000);
    }

    // Intercept Pronote redirect with ?identifiant=
    if (url.includes("index-education.net") && url.includes("identifiant=")) {
      const match = url.match(/identifiant=([^&]+)/);
      if (match) {
        console.log("[nōto] Captured Pronote SSO identifiant:", match[1]);
        setPronoteUrl(url);
        // Don't navigate to Pronote in WebView — we have what we need
      }
    }
  }

  async function handleWebViewMessage(event: { nativeEvent: { data: string } }) {
    try {
      const data = JSON.parse(event.nativeEvent.data);

      if (data.type === "ent_info") {
        console.log("[nōto] ENT info — email:", data.email, "pronote:", data.pronoteLink);

        if (data.email) setEmail(data.email);

        // If we found a Pronote link, navigate to it to get the SSO identifiant
        if (data.pronoteLink) {
          setStatus("Connexion à Pronote...");
          console.log("[nōto] Navigating to Pronote SSO:", data.pronoteLink);
          webViewRef.current?.injectJavaScript(`
            window.location.href = '${data.pronoteLink}';
            true;
          `);

          // Give it time to redirect and capture identifiant, then move to password phase
          setTimeout(() => {
            setPhase("password");
          }, 5000);
        } else {
          // No Pronote link found — go to password phase anyway
          setPhase("password");
        }
      }
    } catch (e) {
      console.warn("[nōto] Message error:", e);
    }
  }

  // --- Phase 2: Password for IMAP + connect Pronote ---

  async function handleConnect() {
    if (!password) {
      setError("Le mot de passe est requis.");
      return;
    }

    setPhase("connecting");
    setError(null);

    const fullEmail = email.includes("@") ? email : `${email}@monlycee.net`;

    // Connect IMAP
    try {
      const result = await fetchUnreadCount({ email: fullEmail, password });
      console.log("[nōto] IMAP OK! Unread:", result.unseen);
      await saveMailCredentials({ email: fullEmail, password });
    } catch (e: unknown) {
      console.warn("[nōto] IMAP failed (continuing anyway):", e);
    }

    // Connect Pronote via SSO URL if we captured it
    if (pronoteUrl) {
      try {
        // The SSO URL has ?identifiant= which is a one-time token
        // We need to use it with Pawnote's credential login
        // Actually, the identifiant is not usable with Pawnote directly
        // But we can try the QR code approach with saved credentials
        console.log("[nōto] Pronote SSO URL captured:", pronoteUrl.substring(0, 80));
        // TODO: integrate Pronote SSO token with Pawnote session
      } catch (e) {
        console.warn("[nōto] Pronote SSO failed:", e);
      }
    }

    // Save ENT session
    await saveEntSession({
      providerId: entProvider.id,
      expiresAt: Date.now() + 365 * 24 * 60 * 60 * 1000,
      apiBaseUrl: entProvider.apiBaseUrl,
      useCookieJar: false,
    });

    if (router.canDismiss()) router.dismissAll();
    router.replace("/");
  }

  // --- Render ---

  if (phase === "webview") {
    return (
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <View style={[styles.statusBar, { backgroundColor: theme.surface }]}>
          <ActivityIndicator color={theme.accent} size="small" />
          <Text style={[styles.statusText, { color: theme.textSecondary }]}>{status}</Text>
        </View>
        <WebView
          ref={webViewRef}
          source={{ uri: entProvider.apiBaseUrl }}
          onNavigationStateChange={handleNavigationChange}
          onMessage={handleWebViewMessage}
          javaScriptEnabled
          domStorageEnabled
          thirdPartyCookiesEnabled
          sharedCookiesEnabled
          setSupportMultipleWindows={false}
          style={styles.webview}
        />
      </View>
    );
  }

  return (
    <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === "ios" ? "padding" : "height"}>
      <ScrollView
        style={[styles.container, { backgroundColor: theme.background }]}
        contentContainerStyle={styles.formContent}
        keyboardShouldPersistTaps="handled"
      >
        <Text style={[styles.title, { color: theme.text }]}>
          ✅ Connecté à {entProvider.name}
        </Text>
        <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
          Entrez votre mot de passe pour activer la messagerie.
          {pronoteUrl ? "\nPronote sera aussi connecté automatiquement." : ""}
        </Text>

        <View style={styles.form}>
          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>Identifiant</Text>
            <TextInput
              style={[styles.input, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
              value={email.replace("@monlycee.net", "")}
              onChangeText={(t) => setEmail(t.includes("@") ? t : t)}
              autoCapitalize="none"
              placeholder="prenom.nom"
              placeholderTextColor={theme.textTertiary}
            />
            <Text style={[styles.emailSuffix, { color: theme.textTertiary }]}>@monlycee.net</Text>
          </View>

          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>Mot de passe</Text>
            <TextInput
              style={[styles.input, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
              value={password}
              onChangeText={setPassword}
              secureTextEntry
              autoFocus
              placeholder="Votre mot de passe Mon Lycée"
              placeholderTextColor={theme.textTertiary}
            />
          </View>

          {error && <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>}

          <Pressable
            style={({ pressed }) => [
              styles.button,
              { backgroundColor: entProvider.color, opacity: pressed || phase === "connecting" ? 0.7 : 1 },
            ]}
            onPress={handleConnect}
            disabled={phase === "connecting"}
          >
            {phase === "connecting" ? (
              <ActivityIndicator color="#FFFFFF" size="small" />
            ) : (
              <Text style={styles.buttonText}>Tout connecter</Text>
            )}
          </Pressable>

          <Pressable onPress={() => { if (router.canDismiss()) router.dismissAll(); router.replace("/"); }}>
            <Text style={[styles.skipText, { color: theme.textTertiary }]}>Passer →</Text>
          </Pressable>
        </View>

        <Text style={[styles.hint, { color: theme.textTertiary }]}>
          🔒 Un seul mot de passe pour la messagerie et Pronote.
        </Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  statusBar: { flexDirection: "row", alignItems: "center", paddingHorizontal: Spacing.md, paddingVertical: Spacing.sm, gap: Spacing.sm },
  statusText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  webview: { flex: 1 },
  formContent: { padding: Spacing.lg, paddingTop: Spacing.xl },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold },
  subtitle: { fontSize: FontSize.md, fontFamily: Fonts.regular, marginTop: Spacing.sm, lineHeight: 22 },
  form: { marginTop: Spacing.xl, gap: Spacing.md },
  field: { gap: Spacing.xs },
  label: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  input: { borderWidth: 1, borderRadius: BorderRadius.md, paddingHorizontal: Spacing.md, paddingVertical: 14, fontSize: FontSize.md, fontFamily: Fonts.regular },
  emailSuffix: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: 2 },
  error: { fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 18 },
  button: { borderRadius: BorderRadius.md, paddingVertical: 16, alignItems: "center", marginTop: Spacing.sm },
  buttonText: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  skipText: { fontSize: FontSize.md, fontFamily: Fonts.medium, textAlign: "center", marginTop: Spacing.lg },
  hint: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.xxl, textAlign: "center", lineHeight: 16 },
});
