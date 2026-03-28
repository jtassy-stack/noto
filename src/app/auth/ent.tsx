import { useState, useRef } from "react";
import { View, Text, StyleSheet, ActivityIndicator } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import type { WebViewNavigation } from "react-native-webview";
import CookieManager from "@react-native-cookies/cookies";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { saveEntSession } from "@/lib/ent/auth";
import { getEntProvider, ENT_PROVIDERS } from "@/lib/ent/providers";

export default function EntLoginScreen() {
  const theme = useTheme();
  const { provider: providerId } = useLocalSearchParams<{ provider: string }>();
  const entProvider = getEntProvider(providerId ?? "") ?? ENT_PROVIDERS[0]!;

  const [loading, setLoading] = useState(true);
  const sawCallbackRef = useRef(false);
  const doneRef = useRef(false);
  const webViewRef = useRef<WebView>(null);

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView:", url.substring(0, 80));

    // Track: have we seen the OAuth callback? This means Keycloak login succeeded.
    if (url.includes("/oauth2/callback")) {
      sawCallbackRef.current = true;
      console.log("[nōto] Saw OAuth callback — login succeeded");
    }

    // After seeing the callback, wait for final landing on the ENT homepage
    if (
      sawCallbackRef.current &&
      !doneRef.current &&
      url.startsWith(entProvider.apiBaseUrl) &&
      !url.includes("/oauth2/callback") &&
      !url.includes("/cas/init") &&
      !url.includes("auth.monlycee.net")
    ) {
      doneRef.current = true;
      console.log("[nōto] On ENT homepage after login, extracting cookies...");

      // Use CookieManager to get ALL cookies including HttpOnly
      setTimeout(async () => {
        try {
          const cookies = await CookieManager.get(entProvider.apiBaseUrl);
          console.log("[nōto] CookieManager cookies:", Object.keys(cookies));

          // Build cookie header string from all cookies
          const cookieString = Object.entries(cookies)
            .map(([name, cookie]) => `${name}=${cookie.value}`)
            .join("; ");

          console.log("[nōto] Cookie string:", cookieString.substring(0, 150));

          if (!cookieString) {
            console.warn("[nōto] No cookies found!");
            return;
          }

          await saveEntSession({
            providerId: entProvider.id,
            expiresAt: Date.now() + 24 * 60 * 60 * 1000,
            apiBaseUrl: entProvider.apiBaseUrl,
            cookies: cookieString,
          });

          console.log("[nōto] ENT session saved, navigating home...");
          router.replace("/");
        } catch (e) {
          console.warn("[nōto] Cookie extraction error:", e);
        }
      }, 1500);
    }
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      {loading && (
        <View style={styles.loadingOverlay}>
          <ActivityIndicator color={theme.accent} size="large" />
          <Text style={[styles.loadingText, { color: theme.textSecondary }]}>
            Chargement de {entProvider.name}...
          </Text>
        </View>
      )}
      <WebView
        ref={webViewRef}
        source={{ uri: entProvider.apiBaseUrl }}
        onLoadEnd={() => setLoading(false)}
        onNavigationStateChange={handleNavigationChange}
        javaScriptEnabled
        domStorageEnabled
        thirdPartyCookiesEnabled
        sharedCookiesEnabled
        style={loading ? styles.hidden : styles.webview}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  webview: { flex: 1 },
  hidden: { height: 0, opacity: 0 },
  loadingOverlay: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: "center",
    alignItems: "center",
    zIndex: 10,
    gap: Spacing.md,
  },
  loadingText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
  },
});
