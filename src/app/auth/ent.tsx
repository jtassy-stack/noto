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

    if (url.includes("/oauth2/callback")) {
      sawCallbackRef.current = true;
      console.log("[nōto] Saw OAuth callback — login succeeded");
    }

    if (
      sawCallbackRef.current &&
      !doneRef.current &&
      url.startsWith(entProvider.apiBaseUrl) &&
      !url.includes("/oauth2/callback") &&
      !url.includes("/cas/init") &&
      !url.includes("auth.monlycee.net")
    ) {
      doneRef.current = true;
      console.log("[nōto] On ENT homepage, fetching messages from WebView...");

      // Fetch messages from INSIDE the WebView (it has the cookies)
      setTimeout(() => {
        const endpoint = entProvider.messagingType === "zimbra"
          ? "/zimbra/list?folder=INBOX&page=0"
          : "/conversation/api/folders/INBOX/messages?page=0&page_size=20";

        webViewRef.current?.injectJavaScript(`
          (async function() {
            try {
              // Get messages
              const msgRes = await fetch('${entProvider.apiBaseUrl}${endpoint}', {
                headers: { 'Accept': 'application/json' },
                credentials: 'include'
              });
              const msgText = await msgRes.text();

              // Get unread count
              const countEndpoint = '${entProvider.messagingType === "zimbra" ? "/zimbra/count/INBOX?unread=true" : "/conversation/count/INBOX?unread=true"}';
              const countRes = await fetch('${entProvider.apiBaseUrl}' + countEndpoint, {
                headers: { 'Accept': 'application/json' },
                credentials: 'include'
              });
              const countText = await countRes.text();

              window.ReactNativeWebView.postMessage(JSON.stringify({
                type: 'ent_data',
                messages: msgText,
                messagesStatus: msgRes.status,
                unreadCount: countText,
                countStatus: countRes.status,
              }));
            } catch(e) {
              window.ReactNativeWebView.postMessage(JSON.stringify({
                type: 'ent_error',
                error: e.message
              }));
            }
          })();
          true;
        `);
      }, 2000);
    }
  }

  async function handleMessage(event: { nativeEvent: { data: string } }) {
    try {
      const data = JSON.parse(event.nativeEvent.data);

      if (data.type === "ent_data") {
        console.log("[nōto] Messages status:", data.messagesStatus);
        console.log("[nōto] Messages preview:", String(data.messages).substring(0, 150));
        console.log("[nōto] Unread count:", data.unreadCount);

        // Save the fetched messages to the session for the Messages tab
        await saveEntSession({
          providerId: entProvider.id,
          expiresAt: Date.now() + 24 * 60 * 60 * 1000,
          apiBaseUrl: entProvider.apiBaseUrl,
          useCookieJar: true,
          cachedMessages: data.messages,
          cachedUnreadCount: data.unreadCount,
        });

        console.log("[nōto] ENT session + messages saved");
        router.replace("/");
      } else if (data.type === "ent_error") {
        console.warn("[nōto] ENT data fetch error:", data.error);
        // Save session anyway
        await saveEntSession({
          providerId: entProvider.id,
          expiresAt: Date.now() + 24 * 60 * 60 * 1000,
          apiBaseUrl: entProvider.apiBaseUrl,
          useCookieJar: true,
        });
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
