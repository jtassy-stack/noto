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

      // Small delay to let the page fully load and set cookies
      setTimeout(() => {
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
      }, 1000);
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

        console.log("[nōto] ENT session saved with cookies, navigating home...");
        // Use setTimeout to escape the WebView message handler context
        setTimeout(() => {
          console.log("[nōto] Calling router.replace...");
          router.replace("/");
        }, 100);
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
