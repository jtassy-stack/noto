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
  const phaseRef = useRef<"login" | "mail">("login");
  const sawCallbackRef = useRef(false);
  const doneRef = useRef(false);
  const webViewRef = useRef<WebView>(null);

  function handleNavigationChange(event: WebViewNavigation) {
    const url = event.url;
    console.log("[nōto] WebView:", url.substring(0, 80));

    if (phaseRef.current === "login") {
      // Phase 1: Login on psn.monlycee.net via Keycloak
      if (url.includes("auth.monlycee.net") && url.includes("login-actions")) {
        setStatus("Saisissez vos identifiants...");
      }

      if (url.includes("/oauth2/callback")) {
        sawCallbackRef.current = true;
        setStatus("Connexion réussie !");
        console.log("[nōto] OAuth callback — login done");
      }

      // After login, when back on ENT homepage, navigate to webmail
      if (
        sawCallbackRef.current &&
        url.startsWith(entProvider.apiBaseUrl) &&
        !url.includes("/oauth2/callback") &&
        !url.includes("/cas/init") &&
        !url.includes("auth.monlycee.net")
      ) {
        phaseRef.current = "mail";
        setStatus("Chargement de la messagerie...");
        console.log("[nōto] ENT login done, navigating to webmail...");

        // Navigate to the webmail — SSO will auto-authenticate
        setTimeout(() => {
          webViewRef.current?.injectJavaScript(`
            window.location.href = 'https://web-mail.monlycee.net/main.html#inbox';
            true;
          `);
        }, 1000);
      }
    } else if (phaseRef.current === "mail") {
      // Phase 2: On webmail, intercept the token from /me?tok= request
      if (url.includes("web-mail.monlycee.net/main.html") && !doneRef.current) {
        doneRef.current = true;
        setStatus("Récupération des messages...");
        console.log("[nōto] On webmail, intercepting API calls...");

        // Wait for the webmail to load and make its API calls,
        // then monkey-patch XHR to capture the mail data
        setTimeout(() => {
          webViewRef.current?.injectJavaScript(`
            (async function() {
              try {
                // The webmail app stores mail data after loading
                // Wait a bit for XHR calls to complete
                await new Promise(r => setTimeout(r, 3000));

                // Try to read mail list from the DOM
                const mailItems = document.querySelectorAll('.mail-item, .mail-row, [class*="mail"], tr[class*="unread"], tr[class*="read"]');

                // Also try to intercept via the webmail's internal state
                // Look for the getMailHeaderList response in the page
                let messages = [];

                // Parse mail rows: td.from (col 2), td.subject (col 5), td.received (col 9)
                const rows = document.querySelectorAll('table tbody tr');
                rows.forEach((row, i) => {
                  const fromCell = row.querySelector('td.from');
                  const subjectCell = row.querySelector('td.subject');
                  const dateCell = row.querySelector('td.received');
                  if (fromCell && subjectCell) {
                    messages.push({
                      id: 'msg-' + i,
                      from: fromCell.textContent.trim(),
                      subject: subjectCell.textContent.trim(),
                      date: dateCell ? dateCell.textContent.trim() : '',
                      unread: row.classList.contains('new'),
                      hasAttachment: !!row.querySelector('td.attachment .icon-attachment'),
                    });
                  }
                });

                const titleMatch = document.title.match(/\\((\\d+)/);
                const unreadCount = titleMatch ? parseInt(titleMatch[1]) : 0;

                window.ReactNativeWebView.postMessage(JSON.stringify({
                  type: 'mail_data',
                  messages: JSON.stringify(messages),
                  unreadCount: unreadCount,
                  messageCount: messages.length,
                  title: document.title,
                }));
              } catch(e) {
                window.ReactNativeWebView.postMessage(JSON.stringify({
                  type: 'mail_error',
                  error: e.message
                }));
              }
            })();
            true;
          `);
        }, 2000);
      }
    }
  }

  async function handleMessage(event: { nativeEvent: { data: string } }) {
    try {
      const data = JSON.parse(event.nativeEvent.data);

      if (data.type === "mail_data") {
        console.log("[nōto] Got mail data! Count:", data.messageCount, "Unread:", data.unreadCount);
        console.log("[nōto] Title:", data.title);
        console.log("[nōto] Messages:", String(data.messages).substring(0, 200));

        await saveEntSession({
          providerId: entProvider.id,
          expiresAt: Date.now() + 24 * 60 * 60 * 1000,
          apiBaseUrl: entProvider.apiBaseUrl,
          useCookieJar: true,
          cachedMessages: data.messages,
          cachedUnreadCount: String(data.unreadCount),
        });

        console.log("[nōto] ENT session + messages saved");
        // Use router.dismissAll() to close the modal stack, then navigate
        if (router.canDismiss()) {
          router.dismissAll();
        }
        router.replace("/");
      } else if (data.type === "mail_error") {
        console.warn("[nōto] Mail fetch error:", data.error);
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
