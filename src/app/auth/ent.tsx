import { useState, useRef } from "react";
import { View, Text, StyleSheet, ActivityIndicator } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import type { WebViewNavigation } from "react-native-webview";
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

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView:", url.substring(0, 80));

    if (url.includes("/oauth2/callback")) {
      sawCallbackRef.current = true;
      console.log("[nōto] Saw OAuth callback — login succeeded");
    }

    // After callback, when we land on ENT homepage, session cookies are set
    // sharedCookiesEnabled means fetch() will have them too
    if (
      sawCallbackRef.current &&
      !doneRef.current &&
      url.startsWith(entProvider.apiBaseUrl) &&
      !url.includes("/oauth2/callback") &&
      !url.includes("/cas/init") &&
      !url.includes("auth.monlycee.net")
    ) {
      doneRef.current = true;
      console.log("[nōto] On ENT homepage after login, testing session...");

      // Wait for cookies to settle, then test the session via fetch()
      setTimeout(async () => {
        try {
          // Test if fetch() now has the session cookies (shared from WebView)
          const testUrl = entProvider.messagingType === "zimbra"
            ? `${entProvider.apiBaseUrl}/zimbra/count/INBOX?unread=true`
            : `${entProvider.apiBaseUrl}/conversation/count/INBOX?unread=true`;

          const res = await fetch(testUrl, {
            headers: { Accept: "application/json" },
            credentials: "include",
          });

          const text = await res.text();
          console.log("[nōto] Session test:", res.status, text.substring(0, 80));

          const sessionWorks = res.ok && !text.includes("<!DOCTYPE");

          await saveEntSession({
            providerId: entProvider.id,
            expiresAt: Date.now() + 24 * 60 * 60 * 1000,
            apiBaseUrl: entProvider.apiBaseUrl,
            useCookieJar: true, // Use RN's shared cookie jar, no manual cookies
          });

          console.log("[nōto] ENT session saved (cookie jar mode), API works:", sessionWorks);
          router.replace("/");
        } catch (e) {
          console.warn("[nōto] Session test error:", e);
          // Save session anyway — cookies might work for other endpoints
          await saveEntSession({
            providerId: entProvider.id,
            expiresAt: Date.now() + 24 * 60 * 60 * 1000,
            apiBaseUrl: entProvider.apiBaseUrl,
            useCookieJar: true,
          });
          router.replace("/");
        }
      }, 2000);
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
