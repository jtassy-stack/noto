import { useEffect, useState } from "react";
import { View, Text, ScrollView, StyleSheet, ActivityIndicator, useColorScheme } from "react-native";
import { useLocalSearchParams } from "expo-router";
import { WebView } from "react-native-webview";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { stripHtml } from "@/lib/utils/html";
import { LightTheme, DarkTheme } from "@/constants/theme";

export default function DetailScreen() {
  const theme = useTheme();
  const scheme = useColorScheme();
  const { id, title, from, date, type, body: passedBody } = useLocalSearchParams<{
    id: string;
    title: string;
    from: string;
    date: string;
    type: string; // "blog" | "timeline" | "message"
    body: string;
  }>();

  const [htmlContent, setHtmlContent] = useState<string | null>(null);
  const [plainText, setPlainText] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [apiBaseUrl, setApiBaseUrl] = useState("");

  useEffect(() => {
    async function load() {
      if (passedBody && type !== "blog") {
        setPlainText(stripHtml(passedBody));
        setLoading(false);
        return;
      }

      if (!id) { setLoading(false); return; }

      try {
        const creds = await getConversationCredentials();
        if (!creds) { setLoading(false); return; }

        setApiBaseUrl(creds.apiBaseUrl);

        // Login
        await fetch(`${creds.apiBaseUrl}/auth/login`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
          redirect: "follow",
        });

        if (type === "blog") {
          // Fetch blog posts — they contain rich HTML with images
          const res = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${id}`, {
            headers: { Accept: "application/json" },
          });
          if (res.ok) {
            const posts = await res.json();
            if (Array.isArray(posts) && posts.length > 0) {
              // Combine all posts as HTML
              const html = posts.map((p: Record<string, unknown>) => {
                const postTitle = String(p.title ?? "");
                const content = String(p.content ?? "");
                const postDate = p.created ? new Date(String((p.created as Record<string, string>).$date ?? p.created)).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" }) : "";
                return `<h3>${postTitle}</h3><p style="color:gray;font-size:12px;">${postDate}</p>${content}`;
              }).join("<hr/>");
              setHtmlContent(html);
            }
          }
        } else if (type === "message") {
          const res = await fetch(`${creds.apiBaseUrl}/conversation/message/${id}`, {
            headers: { Accept: "application/json" },
          });
          if (res.ok) {
            const msg = await res.json() as Record<string, unknown>;
            const body = String(msg.body ?? "");
            if (body.includes("<img") || body.includes("<table") || body.includes("<iframe")) {
              setHtmlContent(body);
            } else {
              setPlainText(stripHtml(body));
            }
          }
        }
      } catch (e) {
        console.warn("[nōto] Detail fetch error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, type, passedBody]);

  // Build styled HTML for WebView
  const isDark = scheme === "dark";
  const colors = isDark ? DarkTheme : LightTheme;

  function wrapHtml(html: string): string {
    return `<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    body {
      font-family: -apple-system, system-ui, sans-serif;
      font-size: 16px;
      line-height: 1.6;
      color: ${colors.text};
      background: ${colors.background};
      padding: 0 4px;
      margin: 0;
    }
    img {
      max-width: 100%;
      height: auto;
      border-radius: 8px;
      margin: 8px 0;
    }
    video, iframe {
      max-width: 100%;
      border-radius: 8px;
      margin: 8px 0;
    }
    a { color: ${colors.accent}; }
    h1, h2, h3 { color: ${colors.text}; margin: 12px 0 4px; }
    hr { border: none; border-top: 1px solid ${colors.border}; margin: 16px 0; }
    p { margin: 8px 0; }
    table { border-collapse: collapse; width: 100%; }
    td, th { border: 1px solid ${colors.border}; padding: 6px 8px; }
  </style>
</head>
<body>${html}</body>
</html>`;
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={[styles.title, { color: theme.text }]}>
          {type === "blog" ? title : (title ? stripHtml(title) : "(sans titre)")}
        </Text>
        <View style={styles.metaRow}>
          {from ? <Text style={[styles.from, { color: theme.accent }]}>{from}</Text> : null}
          {date ? <Text style={[styles.date, { color: theme.textTertiary }]}>{date}</Text> : null}
        </View>
        <View style={[styles.divider, { backgroundColor: theme.border }]} />
      </View>

      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}

      {/* Rich HTML content (blog with images, formatted messages) */}
      {htmlContent && (
        <WebView
          source={{ html: wrapHtml(htmlContent), baseUrl: apiBaseUrl }}
          style={styles.webview}
          scrollEnabled={true}
          nestedScrollEnabled={true}
          originWhitelist={["*"]}
          javaScriptEnabled={false}
          showsVerticalScrollIndicator={false}
        />
      )}

      {/* Plain text content */}
      {plainText && (
        <ScrollView contentContainerStyle={styles.bodyContainer}>
          <Text style={[styles.body, { color: theme.text }]}>{plainText}</Text>
        </ScrollView>
      )}

      {!loading && !htmlContent && !plainText && (
        <Text style={[styles.empty, { color: theme.textTertiary }]}>
          Pas de contenu disponible.
        </Text>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  header: { padding: Spacing.lg, paddingBottom: 0 },
  title: { fontSize: FontSize.xl, fontFamily: Fonts.bold, lineHeight: 28 },
  metaRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginTop: Spacing.sm },
  from: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, flex: 1 },
  date: { fontSize: FontSize.sm, fontFamily: Fonts.mono },
  divider: { height: 1, marginTop: Spacing.md },
  webview: { flex: 1 },
  bodyContainer: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  body: { fontSize: FontSize.md, fontFamily: Fonts.regular, lineHeight: 24 },
  empty: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", marginTop: Spacing.xl, padding: Spacing.lg },
});
