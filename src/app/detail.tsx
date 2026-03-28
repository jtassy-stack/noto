import { useEffect, useState } from "react";
import { View, Text, ScrollView, Pressable, StyleSheet, ActivityIndicator, useColorScheme } from "react-native";
import { useLocalSearchParams, router } from "expo-router";
import { WebView } from "react-native-webview";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { stripHtml } from "@/lib/utils/html";
import { LightTheme, DarkTheme } from "@/constants/theme";

interface BlogPost {
  id: string;
  title: string;
  content: string;
  date: string;
}

export default function DetailScreen() {
  const theme = useTheme();
  const scheme = useColorScheme();
  const { id, title, from, date, type, body: passedBody, postContent } = useLocalSearchParams<{
    id: string;
    title: string;
    from: string;
    date: string;
    type: string; // "blog" | "blogpost" | "timeline"
    body: string;
    postContent: string;
  }>();

  const [blogPosts, setBlogPosts] = useState<BlogPost[]>([]);
  const [htmlContent, setHtmlContent] = useState<string | null>(null);
  const [plainText, setPlainText] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [apiBaseUrl, setApiBaseUrl] = useState("");

  useEffect(() => {
    async function load() {
      // Blog post detail — content passed as param
      if (type === "blogpost" && postContent) {
        setHtmlContent(postContent);
        setLoading(false);
        return;
      }

      // Timeline — plain text
      if (type === "timeline" && passedBody) {
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
          // Fetch blog posts list for this blog
          const res = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${id}`, {
            headers: { Accept: "application/json" },
          });
          if (res.ok) {
            const posts = await res.json();
            if (Array.isArray(posts)) {
              setBlogPosts(posts.map((p: Record<string, unknown>) => ({
                id: String(p._id ?? ""),
                title: String(p.title ?? ""),
                content: String(p.content ?? ""),
                date: p.created && typeof p.created === "object" && "$date" in (p.created as Record<string, string>)
                  ? new Date(String((p.created as Record<string, string>).$date)).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" })
                  : "",
              })));
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
  }, [id, type, passedBody, postContent]);

  // Styled HTML for WebView (blog post content with images)
  const isDark = scheme === "dark";
  const colors = isDark ? DarkTheme : LightTheme;

  function wrapHtml(html: string): string {
    // Make relative image URLs absolute
    const fixedHtml = html.replace(/src="\//g, `src="${apiBaseUrl}/`);
    return `<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, sans-serif; font-size: 16px; line-height: 1.6; color: ${colors.text}; background: ${colors.background}; padding: 0 4px; margin: 0; }
  img { max-width: 100%; height: auto; border-radius: 8px; margin: 8px 0; }
  video, iframe { max-width: 100%; border-radius: 8px; margin: 8px 0; }
  a { color: ${colors.accent}; }
  h1, h2, h3 { color: ${colors.text}; }
  hr { border: none; border-top: 1px solid ${colors.border}; margin: 16px 0; }
</style>
</head><body>${fixedHtml}</body></html>`;
  }

  // Blog: list of posts
  if (type === "blog" && blogPosts.length > 0) {
    return (
      <ScrollView
        style={[styles.container, { backgroundColor: theme.background }]}
        contentContainerStyle={styles.listContent}
      >
        {blogPosts.map((post) => (
          <Pressable
            key={post.id}
            onPress={() => router.push({
              pathname: "/detail",
              params: { id: post.id, title: post.title, date: post.date, type: "blogpost", postContent: post.content },
            })}
            style={[styles.postCard, { backgroundColor: theme.surface, borderColor: theme.border }]}
          >
            <Text style={[styles.postTitle, { color: theme.text }]} numberOfLines={2}>
              {post.title}
            </Text>
            <Text style={[styles.postDate, { color: theme.textTertiary }]}>{post.date}</Text>
            <Text style={[styles.postPreview, { color: theme.textSecondary }]} numberOfLines={2}>
              {stripHtml(post.content)}
            </Text>
          </Pressable>
        ))}
      </ScrollView>
    );
  }

  // Blog post or rich content: WebView
  if (htmlContent) {
    return (
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <View style={styles.header}>
          <Text style={[styles.title, { color: theme.text }]}>{title}</Text>
          {date ? <Text style={[styles.date, { color: theme.textTertiary }]}>{date}</Text> : null}
          <View style={[styles.divider, { backgroundColor: theme.border }]} />
        </View>
        <WebView
          source={{ html: wrapHtml(htmlContent), baseUrl: apiBaseUrl }}
          style={styles.webview}
          scrollEnabled
          originWhitelist={["*"]}
          javaScriptEnabled={false}
        />
      </View>
    );
  }

  // Plain text
  if (plainText) {
    return (
      <ScrollView
        style={[styles.container, { backgroundColor: theme.background }]}
        contentContainerStyle={styles.textContent}
      >
        <Text style={[styles.title, { color: theme.text }]}>{title ? stripHtml(title) : ""}</Text>
        <View style={styles.metaRow}>
          {from ? <Text style={[styles.from, { color: theme.accent }]}>{from}</Text> : null}
          {date ? <Text style={[styles.dateSmall, { color: theme.textTertiary }]}>{date}</Text> : null}
        </View>
        <View style={[styles.divider, { backgroundColor: theme.border }]} />
        <Text style={[styles.body, { color: theme.text }]}>{plainText}</Text>
      </ScrollView>
    );
  }

  // Loading
  return (
    <View style={[styles.container, { backgroundColor: theme.background, justifyContent: "center", alignItems: "center" }]}>
      {loading ? <ActivityIndicator color={theme.accent} /> : (
        <Text style={[styles.empty, { color: theme.textTertiary }]}>Pas de contenu disponible.</Text>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  listContent: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  postCard: { padding: Spacing.md, borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: Spacing.sm, gap: 4 },
  postTitle: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, lineHeight: 22 },
  postDate: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  postPreview: { fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 18 },
  header: { padding: Spacing.lg, paddingBottom: 0 },
  title: { fontSize: FontSize.xl, fontFamily: Fonts.bold, lineHeight: 28 },
  date: { fontSize: FontSize.sm, fontFamily: Fonts.mono, marginTop: Spacing.xs },
  metaRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginTop: Spacing.sm },
  from: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, flex: 1 },
  dateSmall: { fontSize: FontSize.sm, fontFamily: Fonts.mono },
  divider: { height: 1, marginVertical: Spacing.md },
  webview: { flex: 1 },
  textContent: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  body: { fontSize: FontSize.md, fontFamily: Fonts.regular, lineHeight: 24 },
  empty: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center" },
});
