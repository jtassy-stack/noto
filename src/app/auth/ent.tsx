import { useState, useRef } from "react";
import { View, Text, StyleSheet, ActivityIndicator } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import type { WebViewNavigation } from "react-native-webview";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getEntProvider, ENT_PROVIDERS } from "@/lib/ent/providers";
import { saveMailCredentials } from "@/lib/ent/mail";
import { saveEntSession } from "@/lib/ent/auth";

// Single phase: WebView handles everything automatically

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const [status, setStatus] = useState("Connexion à " + entProvider.name + "...");
  const [email, setEmail] = useState("");
  const [pronoteUrl, setPronoteUrl] = useState("");
  const [password, setPassword] = useState("");

  const sawCallbackRef = useRef(false);
  const doneRef = useRef(false);
  const webViewRef = useRef<WebView>(null);

  // --- Phase 1: WebView → Keycloak login → scrape email + Pronote URL ---

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView:", url.substring(0, 80));

    if (url.includes("auth.monlycee.net") && url.includes("login-actions")) {
      setStatus("Saisissez vos identifiants...");

      // Inject a listener to capture credentials from the Keycloak form
      setTimeout(() => {
        webViewRef.current?.injectJavaScript(`
          (function() {
            if (window.__notoInjected) return;
            window.__notoInjected = true;

            const form = document.querySelector('form');
            if (form) {
              form.addEventListener('submit', function() {
                const user = document.querySelector('input[name="username"]');
                const pass = document.querySelector('input[name="password"]');
                if (user && pass) {
                  window.ReactNativeWebView.postMessage(JSON.stringify({
                    type: 'credentials',
                    username: user.value,
                    password: pass.value,
                  }));
                }
              });
            }
          })();
          true;
        `);
      }, 1000);
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

      if (data.type === "credentials") {
        console.log("[nōto] Captured credentials — user:", data.username);
        // Save password for IMAP (same as Keycloak)
        setPassword(data.password);
        const fullEmail = data.username.includes("@")
          ? data.username
          : `${data.username}@monlycee.net`;
        setEmail(fullEmail);
      }

      if (data.type === "ent_info") {
        console.log("[nōto] ENT info — email:", data.email, "pronote:", data.pronoteLink);

        if (data.email && !email) setEmail(data.email);

        // Navigate to Pronote link to capture SSO identifiant
        if (data.pronoteLink) {
          setStatus("Connexion à Pronote...");
          console.log("[nōto] Navigating to Pronote SSO:", data.pronoteLink);
          webViewRef.current?.injectJavaScript(`
            window.location.href = '${data.pronoteLink}';
            true;
          `);

          // Wait for Pronote redirect, then finish
          setTimeout(() => {
            finishLogin();
          }, 5000);
        } else {
          finishLogin();
        }
      }
    } catch (e) {
      console.warn("[nōto] Message error:", e);
    }
  }

  async function finishLogin() {
    setStatus("Finalisation...");

    const fullEmail = email.includes("@") ? email : `${email}@monlycee.net`;

    // Save IMAP credentials if we captured the password
    if (password && fullEmail) {
      try {
        await saveMailCredentials({ email: fullEmail, password });
        console.log("[nōto] IMAP credentials saved for", fullEmail);
      } catch (e) {
        console.warn("[nōto] Failed to save mail credentials:", e);
      }
    }

    // Save ENT session
    await saveEntSession({
      providerId: entProvider.id,
      expiresAt: Date.now() + 365 * 24 * 60 * 60 * 1000,
      apiBaseUrl: entProvider.apiBaseUrl,
      useCookieJar: false,
    });

    console.log("[nōto] All done! Email:", fullEmail, "Pronote URL:", pronoteUrl ? "captured" : "none");

    if (router.canDismiss()) router.dismissAll();
    router.replace("/");
  }

  // --- Render: WebView only (everything is automatic) ---

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

const styles = StyleSheet.create({
  container: { flex: 1 },
  statusBar: { flexDirection: "row", alignItems: "center", paddingHorizontal: Spacing.md, paddingVertical: Spacing.sm, gap: Spacing.sm },
  statusText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  webview: { flex: 1 },
});
