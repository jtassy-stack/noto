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
  const [loggedIn, setLoggedIn] = useState(false);
  const webViewRef = useRef<WebView>(null);

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView navigated to:", url.substring(0, 100));

    // After Keycloak login, user is redirected back to the ENT homepage
    // When the URL is on the ENT domain (not auth.monlycee.net), login is done
    if (
      !loggedIn &&
      url.startsWith(entProvider.apiBaseUrl) &&
      !url.includes("/auth/login") &&
      !url.includes("/oauth2/callback") &&
      !url.includes("auth.monlycee.net")
    ) {
      console.log("[nōto] ENT login detected, extracting cookies...");
      setLoggedIn(true);

      // Inject JS to extract cookies from the WebView
      webViewRef.current?.injectJavaScript(`
        (function() {
          window.ReactNativeWebView.postMessage(JSON.stringify({
            type: 'cookies',
            cookies: document.cookie,
            url: window.location.href
          }));
        })();
        true;
      `);
    }
  }

  async function handleMessage(event: { nativeEvent: { data: string } }) {
    try {
      const data = JSON.parse(event.nativeEvent.data) as {
        type: string;
        cookies: string;
        url: string;
      };

      if (data.type === "cookies") {
        console.log("[nōto] Got cookies from WebView:", data.cookies.substring(0, 100));
        console.log("[nōto] Current URL:", data.url);

        await saveEntSession({
          providerId: entProvider.id,
          expiresAt: Date.now() + 24 * 60 * 60 * 1000,
          apiBaseUrl: entProvider.apiBaseUrl,
          cookies: data.cookies,
        });

        console.log("[nōto] ENT session saved with cookies");
        router.replace("/");
      }
    } catch (e) {
      console.warn("[nōto] WebView message parse error:", e);
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
        onMessage={handleMessage}
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
