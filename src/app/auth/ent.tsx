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

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const [status, setStatus] = useState("Connexion à " + entProvider.name + "...");

  const usernameRef = useRef("");
  const passwordRef = useRef("");
  const pronoteIdentRef = useRef("");
  const sawCallbackRef = useRef(false);
  const doneRef = useRef(false);
  const finishingRef = useRef(false);
  const webViewRef = useRef<WebView>(null);

  // JS to inject on EVERY page load to capture credentials
  const INJECT_JS = `
    (function() {
      // Capture credentials from Keycloak login form
      const form = document.querySelector('form#kc-form-login, form[action*="authenticate"]');
      if (form && !form.__notoHooked) {
        form.__notoHooked = true;

        // Hook the submit button click
        const btn = form.querySelector('input[type="submit"], button[type="submit"]');
        if (btn) {
          btn.addEventListener('click', function() {
            const user = form.querySelector('input[name="username"], input[name="email"]');
            const pass = form.querySelector('input[name="password"]');
            if (user && pass && pass.value) {
              window.ReactNativeWebView.postMessage(JSON.stringify({
                type: 'creds',
                u: user.value,
                p: pass.value,
              }));
            }
          });
        }

        // Also hook form submit
        form.addEventListener('submit', function() {
          const user = form.querySelector('input[name="username"], input[name="email"]');
          const pass = form.querySelector('input[name="password"]');
          if (user && pass && pass.value) {
            window.ReactNativeWebView.postMessage(JSON.stringify({
              type: 'creds',
              u: user.value,
              p: pass.value,
            }));
          }
        });
      }

      // On ENT portal: find email + Pronote link
      if (window.location.hostname.includes('psn.monlycee.net') && !window.__notoScraped) {
        window.__notoScraped = true;
        setTimeout(function() {
          // Find Pronote link
          var pronoteLink = '';
          var links = document.querySelectorAll('a');
          for (var i = 0; i < links.length; i++) {
            if (links[i].href && links[i].href.includes('pronote') && links[i].href.includes('parent.html')) {
              pronoteLink = links[i].href;
              break;
            }
          }

          // Find email
          var email = '';
          var allText = document.querySelectorAll('span, div, p, a');
          for (var j = 0; j < allText.length; j++) {
            var t = allText[j].textContent.trim();
            var m = t.match(/[a-zA-Z0-9._%+-]+@monlycee\\.net/);
            if (m) { email = m[0]; break; }
          }

          if (pronoteLink || email) {
            window.ReactNativeWebView.postMessage(JSON.stringify({
              type: 'portal',
              email: email,
              pronoteLink: pronoteLink,
            }));
          }
        }, 2000);
      }
    })();
    true;
  `;

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView:", url.substring(0, 80));

    if (url.includes("auth.monlycee.net")) {
      setStatus("Saisissez vos identifiants...");
    }

    if (url.includes("/oauth2/callback")) {
      sawCallbackRef.current = true;
      setStatus("Connexion réussie !");
    }

    // Capture Pronote SSO identifiant from URL
    if (url.includes("index-education.net") && url.includes("identifiant=")) {
      const match = url.match(/identifiant=([^&]+)/);
      if (match && match[1]) {
        pronoteIdentRef.current = match[1];
        console.log("[nōto] Pronote identifiant:", match[1]);
      }
    }

    // After login + Pronote SSO, if we have credentials, auto-finish
    if (sawCallbackRef.current && pronoteIdentRef.current && !finishingRef.current) {
      // Wait a bit then finish
      finishingRef.current = true;
      setTimeout(() => finishLogin(), 2000);
    }
  }

  async function handleMessage(event: { nativeEvent: { data: string } }) {
    try {
      const data = JSON.parse(event.nativeEvent.data);

      if (data.type === "creds") {
        console.log("[nōto] Got credentials — user:", data.u);
        usernameRef.current = data.u;
        passwordRef.current = data.p;
      }

      if (data.type === "portal") {
        console.log("[nōto] Portal — email:", data.email, "pronote:", data.pronoteLink?.substring(0, 60));

        // Navigate to Pronote SSO link
        if (data.pronoteLink && !doneRef.current) {
          doneRef.current = true;
          setStatus("Connexion à Pronote...");
          webViewRef.current?.injectJavaScript(`
            window.location.href = '${data.pronoteLink}';
            true;
          `);
        }
      }
    } catch (e) {
      console.warn("[nōto] Message error:", e);
    }
  }

  async function finishLogin() {
    setStatus("Finalisation...");

    const username = usernameRef.current;
    const password = passwordRef.current;
    const pronoteIdent = pronoteIdentRef.current;

    console.log("[nōto] Finishing — user:", username, "pronote:", pronoteIdent ? "yes" : "no", "password:", password ? "yes" : "no");

    // Build email from username
    const fullEmail = username.includes("@") ? username : `${username}@monlycee.net`;

    // Save IMAP credentials
    if (username && password) {
      try {
        await saveMailCredentials({ email: fullEmail, password });
        console.log("[nōto] IMAP credentials saved for", fullEmail);
      } catch (e) {
        console.warn("[nōto] IMAP save error:", e);
      }
    }

    // Save ENT session with Pronote identifiant
    await saveEntSession({
      providerId: entProvider.id,
      expiresAt: Date.now() + 365 * 24 * 60 * 60 * 1000,
      apiBaseUrl: entProvider.apiBaseUrl,
      useCookieJar: false,
      pronoteIdentifiant: pronoteIdent || undefined,
      pronoteBaseUrl: pronoteIdent ? "https://0752546k.index-education.net/pronote/" : undefined,
    });

    console.log("[nōto] All saved! Navigating home...");

    if (router.canDismiss()) router.dismissAll();
    router.replace("/");
  }

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
        onMessage={handleMessage}
        injectedJavaScript={INJECT_JS}
        injectedJavaScriptBeforeContentLoaded={INJECT_JS}
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
