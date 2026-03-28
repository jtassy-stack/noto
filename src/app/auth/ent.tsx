import { useState, useRef } from "react";
import { View, Text, TextInput, Pressable, StyleSheet, ActivityIndicator, KeyboardAvoidingView, Platform } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { saveEntSession } from "@/lib/ent/auth";
import { getEntProvider, ENT_PROVIDERS } from "@/lib/ent/providers";

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const webViewRef = useRef<WebView>(null);
  const [showWebView, setShowWebView] = useState(false);

  async function handleLogin() {
    if (!username || !password) {
      setError("Tous les champs sont requis.");
      return;
    }
    setLoading(true);
    setError(null);
    setShowWebView(true);

    // The WebView will execute the login + fetch messages via injected JS
    // We use a hidden WebView as a "fetch engine" that has its own cookie jar
  }

  function onWebViewLoaded() {
    if (!loading) return;

    // Inject JS that does: login → check XSRF-TOKEN → fetch messages
    const loginScript = `
      (async function() {
        try {
          // Step 1: Login via POST /auth/login
          const loginRes = await fetch('${entProvider.apiBaseUrl}/auth/login', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'email=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}',
            credentials: 'include',
          });

          // Step 2: Check if XSRF-TOKEN cookie exists (= login success)
          const cookies = document.cookie;
          const hasXsrf = cookies.includes('XSRF-TOKEN');

          if (!hasXsrf) {
            window.ReactNativeWebView.postMessage(JSON.stringify({
              type: 'login_error',
              error: 'Identifiants incorrects'
            }));
            return;
          }

          // Step 3: Get user info
          let userName = '';
          try {
            const userRes = await fetch('${entProvider.apiBaseUrl}/auth/oauth2/userinfo', {
              credentials: 'include',
              headers: { 'Accept': 'application/json' }
            });
            if (userRes.ok) {
              const userInfo = await userRes.json();
              userName = userInfo.username || userInfo.login || userInfo.firstName || '';
            }
          } catch(e) {}

          // Step 4: Fetch messages from Zimbra
          let messages = '[]';
          let unreadCount = '0';
          try {
            const msgRes = await fetch('${entProvider.apiBaseUrl}/zimbra/list?folder=%2FInbox&page=0&unread=false', {
              credentials: 'include',
              headers: { 'Accept': 'application/json' }
            });
            if (msgRes.ok) {
              messages = await msgRes.text();
            }

            const countRes = await fetch('${entProvider.apiBaseUrl}/zimbra/count/INBOX?unread=true', {
              credentials: 'include',
              headers: { 'Accept': 'application/json' }
            });
            if (countRes.ok) {
              unreadCount = await countRes.text();
            }
          } catch(e) {}

          window.ReactNativeWebView.postMessage(JSON.stringify({
            type: 'login_success',
            userName: userName,
            messages: messages,
            unreadCount: unreadCount,
            cookies: cookies,
          }));
        } catch(e) {
          window.ReactNativeWebView.postMessage(JSON.stringify({
            type: 'login_error',
            error: e.message || 'Erreur inconnue'
          }));
        }
      })();
      true;
    `;

    webViewRef.current?.injectJavaScript(loginScript);
  }

  async function handleMessage(event: { nativeEvent: { data: string } }) {
    try {
      const data = JSON.parse(event.nativeEvent.data);

      if (data.type === "login_success") {
        console.log("[nōto] ENT login success, user:", data.userName);
        console.log("[nōto] Messages:", String(data.messages).substring(0, 100));
        console.log("[nōto] Unread:", data.unreadCount);
        console.log("[nōto] Cookies:", String(data.cookies).substring(0, 100));

        await saveEntSession({
          providerId: entProvider.id,
          expiresAt: Date.now() + 24 * 60 * 60 * 1000,
          apiBaseUrl: entProvider.apiBaseUrl,
          useCookieJar: true,
          cachedMessages: data.messages,
          cachedUnreadCount: data.unreadCount,
        });

        setLoading(false);
        router.replace("/");
      } else if (data.type === "login_error") {
        console.warn("[nōto] ENT login error:", data.error);
        setError(data.error);
        setLoading(false);
        setShowWebView(false);
      }
    } catch (e) {
      console.warn("[nōto] Message parse error:", e);
    }
  }

  return (
    <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === "ios" ? "padding" : "height"}>
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <Text style={[styles.title, { color: theme.text }]}>
          {entProvider.icon} {entProvider.name}
        </Text>
        <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
          Connectez-vous avec vos identifiants {entProvider.name}.
        </Text>

        <View style={styles.form}>
          <View style={styles.field}>
            <Text style={[styles.label, { color: theme.textSecondary }]}>Identifiant</Text>
            <TextInput
              style={[styles.input, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
              placeholder="Votre identifiant ENT"
              placeholderTextColor={theme.textTertiary}
              value={username}
              onChangeText={setUsername}
              autoCapitalize="none"
              autoCorrect={false}
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
          🔒 Vos identifiants sont envoyés directement au serveur {entProvider.name}.
        </Text>

        {/* Hidden WebView used as a fetch engine with its own cookie jar */}
        {showWebView && (
          <WebView
            ref={webViewRef}
            source={{ uri: entProvider.apiBaseUrl }}
            onLoadEnd={onWebViewLoaded}
            onMessage={handleMessage}
            javaScriptEnabled
            domStorageEnabled
            thirdPartyCookiesEnabled
            style={styles.hiddenWebView}
          />
        )}
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: Spacing.lg, paddingTop: Spacing.xl },
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
  hint: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.xl, textAlign: "center", lineHeight: 16 },
  hiddenWebView: { height: 0, width: 0, opacity: 0, position: "absolute" },
});
