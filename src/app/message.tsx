import { useEffect, useState } from "react";
import { View, Text, ScrollView, StyleSheet, ActivityIndicator, useColorScheme } from "react-native";
import { useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { LightTheme, DarkTheme } from "@/constants/theme";
import { getMailCredentials, fetchMessage as fetchImapMessage } from "@/lib/ent/mail";
import { getConversationCredentials, fetchConversationMessage } from "@/lib/ent/conversation";
import { stripHtml } from "@/lib/utils/html";

export default function MessageScreen() {
  const theme = useTheme();
  const scheme = useColorScheme();
  const { id, from, subject, date, source } = useLocalSearchParams<{
    id: string;
    from: string;
    subject: string;
    date: string;
    source: string;
  }>();

  const [htmlContent, setHtmlContent] = useState<string | null>(null);
  const [plainText, setPlainText] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [apiBaseUrl, setApiBaseUrl] = useState("");

  useEffect(() => {
    async function load() {
      if (!id) return;

      const isEnt = source === "ent";
      console.log("[nōto] Opening message:", id, "source:", source);

      try {
        if (isEnt) {
          const creds = await getConversationCredentials();
          if (!creds) { setError("Reconnectez PCN."); return; }
          setApiBaseUrl(creds.apiBaseUrl);

          const msg = await fetchConversationMessage(creds, id);
          const body = msg.body ?? "";

          // Use WebView for rich content (images, tables), plain text otherwise
          if (body.includes("<img") || body.includes("<table") || body.includes("<iframe")) {
            setHtmlContent(body);
          } else {
            setPlainText(stripHtml(body));
          }
        } else {
          const creds = await getMailCredentials();
          if (!creds) { setError("Reconnectez votre messagerie."); return; }

          const msg = await fetchImapMessage(creds, parseInt(id, 10));
          const body = msg.body ?? "";

          if (body.includes("<html") || body.includes("<body") || body.includes("<span") || body.includes("<div")) {
            setHtmlContent(body);
          } else {
            setPlainText(body);
          }
        }
      } catch (e: unknown) {
        setError(e instanceof Error ? e.message : "Erreur");
        console.warn("[nōto] Message fetch error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, source]);

  const isDark = scheme === "dark";
  const colors = isDark ? DarkTheme : LightTheme;

  function wrapHtml(html: string): string {
    return `<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, sans-serif; font-size: 16px; line-height: 1.6; color: ${colors.text}; background: ${colors.background}; padding: 0 4px; margin: 0; }
  img { max-width: 100%; height: auto; border-radius: 8px; margin: 8px 0; }
  a { color: ${colors.accent}; }
  table { border-collapse: collapse; width: 100%; }
  td, th { border: 1px solid ${colors.border}; padding: 6px 8px; }
</style>
</head><body>${html}</body></html>`;
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <View style={styles.header}>
        <Text style={[styles.subject, { color: theme.text }]}>
          {subject || "(sans objet)"}
        </Text>
        <View style={styles.metaRow}>
          <Text style={[styles.from, { color: theme.accent }]}>{from}</Text>
          <Text style={[styles.date, { color: theme.textTertiary }]}>{date}</Text>
        </View>
        <View style={[styles.divider, { backgroundColor: theme.border }]} />
      </View>

      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}
      {error && <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>}

      {htmlContent && (
        <WebView
          source={{ html: wrapHtml(htmlContent), baseUrl: apiBaseUrl }}
          style={styles.webview}
          scrollEnabled
          originWhitelist={["*"]}
          javaScriptEnabled={false}
        />
      )}

      {plainText && (
        <ScrollView contentContainerStyle={styles.bodyContainer}>
          <Text style={[styles.body, { color: theme.text }]}>{plainText}</Text>
        </ScrollView>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  header: { padding: Spacing.lg, paddingBottom: 0 },
  subject: { fontSize: FontSize.xl, fontFamily: Fonts.bold, lineHeight: 28 },
  metaRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginTop: Spacing.sm },
  from: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, flex: 1 },
  date: { fontSize: FontSize.sm, fontFamily: Fonts.mono },
  divider: { height: 1, marginTop: Spacing.md },
  error: { fontSize: FontSize.md, fontFamily: Fonts.regular, padding: Spacing.lg },
  webview: { flex: 1 },
  bodyContainer: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  body: { fontSize: FontSize.md, fontFamily: Fonts.regular, lineHeight: 24 },
});
