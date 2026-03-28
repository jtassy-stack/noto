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

  const [status, setStatus] = useState("Connexion à " + entProvider.name + "...");
  const sawCallbackRef = useRef(false);
  const doneRef = useRef(false);
  const webViewRef = useRef<WebView>(null);

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView:", url.substring(0, 80));

    // Detect Keycloak login page
    if (url.includes("auth.monlycee.net") && url.includes("login-actions")) {
      setStatus("Saisissez vos identifiants...");
    }

    // Detect OAuth callback = login succeeded
    if (url.includes("/oauth2/callback")) {
      sawCallbackRef.current = true;
      setStatus("Connexion réussie, chargement...");
      console.log("[nōto] Saw OAuth callback — login succeeded");
    }

    // After callback, landed on ENT homepage → fetch messages
    if (
      sawCallbackRef.current &&
      !doneRef.current &&
      url.startsWith(entProvider.apiBaseUrl) &&
      !url.includes("/oauth2/callback") &&
      !url.includes("/cas/init") &&
      !url.includes("auth.monlycee.net")
    ) {
      doneRef.current = true;
      setStatus("Récupération des messages...");
      console.log("[nōto] On ENT homepage, fetching messages...");

      setTimeout(() => {
        webViewRef.current?.injectJavaScript(`
          (async function() {
            try {
              let messages = '[]';
              let unreadCount = '0';
              let userName = '';

              // Try user info
              try {
                const uRes = await fetch('/auth/oauth2/userinfo', {
                  credentials: 'include',
                  headers: { 'Accept': 'application/json' }
                });
                if (uRes.ok) {
                  const u = await uRes.json();
                  userName = u.username || u.login || u.firstName || '';
                }
              } catch(e) {}

              // Fetch messages
              try {
                const mRes = await fetch('/zimbra/list?folder=%2FInbox&page=0&unread=false', {
                  credentials: 'include',
                  headers: { 'Accept': 'application/json' }
                });
                if (mRes.ok) messages = await mRes.text();
              } catch(e) {}

              // Fetch unread count
              try {
                const cRes = await fetch('/zimbra/count/INBOX?unread=true', {
                  credentials: 'include',
                  headers: { 'Accept': 'application/json' }
                });
                if (cRes.ok) unreadCount = await cRes.text();
              } catch(e) {}

              window.ReactNativeWebView.postMessage(JSON.stringify({
                type: 'success',
                userName: userName,
                messages: messages,
                unreadCount: unreadCount,
              }));
            } catch(e) {
              window.ReactNativeWebView.postMessage(JSON.stringify({
                type: 'error',
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

      if (data.type === "success") {
        console.log("[nōto] ENT success! User:", data.userName);
        console.log("[nōto] Messages:", String(data.messages).substring(0, 150));
        console.log("[nōto] Unread:", data.unreadCount);

        await saveEntSession({
          providerId: entProvider.id,
          expiresAt: Date.now() + 24 * 60 * 60 * 1000,
          apiBaseUrl: entProvider.apiBaseUrl,
          useCookieJar: true,
          cachedMessages: data.messages,
          cachedUnreadCount: data.unreadCount,
        });

        router.replace("/");
      } else if (data.type === "error") {
        console.warn("[nōto] ENT fetch error:", data.error);
        // Save session anyway, navigate home
        await saveEntSession({
          providerId: entProvider.id,
          expiresAt: Date.now() + 24 * 60 * 60 * 1000,
          apiBaseUrl: entProvider.apiBaseUrl,
          useCookieJar: true,
        });
        router.replace("/");
      }
    } catch (e) {
      console.warn("[nōto] Message parse error:", e);
    }
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <View style={[styles.statusBar, { backgroundColor: theme.surface }]}>
        <ActivityIndicator color={theme.accent} size="small" />
        <Text style={[styles.statusText, { color: theme.textSecondary }]}>
          {status}
        </Text>
      </View>
      <WebView
        ref={webViewRef}
        source={{ uri: entProvider.apiBaseUrl }}
        onNavigationStateChange={handleNavigationChange}
        onMessage={handleMessage}
        javaScriptEnabled
        domStorageEnabled
        thirdPartyCookiesEnabled
        sharedCookiesEnabled
        style={styles.webview}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  statusBar: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: Spacing.md,
    paddingVertical: Spacing.sm,
    gap: Spacing.sm,
  },
  statusText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  webview: { flex: 1 },
});
