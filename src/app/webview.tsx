import { useEffect, useState, useRef } from "react";
import { View, Text, StyleSheet, ActivityIndicator } from "react-native";
import { useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getConversationCredentials } from "@/lib/ent/conversation";

/**
 * Authenticated WebView — logs into PCN then navigates to the target path.
 * Used for schoolbook words and other ENT pages without a JSON API.
 */
export default function AuthWebViewScreen() {
  const theme = useTheme();
  const { title, path } = useLocalSearchParams<{ title: string; path: string }>();
  const [ready, setReady] = useState(false);
  const [baseUrl, setBaseUrl] = useState("");
  const [loginHtml, setLoginHtml] = useState("");
  const webviewRef = useRef<WebView>(null);

  useEffect(() => {
    async function prepare() {
      const creds = await getConversationCredentials();
      if (!creds || !path) return;

      setBaseUrl(creds.apiBaseUrl);

      // Build an HTML page that auto-submits the login form, then redirects to the target
      const targetUrl = `${creds.apiBaseUrl}${path}`;
      const html = `<!DOCTYPE html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body>
<form id="f" method="POST" action="${creds.apiBaseUrl}/auth/login">
  <input type="hidden" name="email" value="${creds.email}" />
  <input type="hidden" name="password" value="${creds.password}" />
  <input type="hidden" name="callBack" value="${targetUrl}" />
</form>
<script>document.getElementById('f').submit();</script>
</body></html>`;

      setLoginHtml(html);
      setReady(true);
    }
    prepare();
  }, [path]);

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      {title && (
        <Text style={[styles.title, { color: theme.text }]} numberOfLines={2}>
          {title}
        </Text>
      )}
      {!ready && (
        <View style={styles.loading}>
          <ActivityIndicator color={theme.accent} />
        </View>
      )}
      {ready && loginHtml && (
        <WebView
          ref={webviewRef}
          source={{ html: loginHtml, baseUrl }}
          style={styles.webview}
          javaScriptEnabled
          originWhitelist={["*"]}
          sharedCookiesEnabled
          startInLoadingState
          renderLoading={() => (
            <ActivityIndicator color={theme.accent} style={styles.loading} />
          )}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  title: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.semiBold,
    padding: Spacing.lg,
    paddingBottom: Spacing.sm,
    lineHeight: 24,
  },
  webview: { flex: 1 },
  loading: { flex: 1, justifyContent: "center", alignItems: "center" },
});
