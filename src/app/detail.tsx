import { useEffect, useState } from "react";
import { View, Text, ScrollView, StyleSheet, ActivityIndicator } from "react-native";
import { useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { stripHtml } from "@/lib/utils/html";

export default function DetailScreen() {
  const theme = useTheme();
  const { id, title, from, date, type, body: passedBody } = useLocalSearchParams<{
    id: string;
    title: string;
    from: string;
    date: string;
    type: string; // "blog" | "timeline" | "text"
    body: string;
  }>();

  const [body, setBody] = useState<string | null>(passedBody ? stripHtml(passedBody) : null);
  const [loading, setLoading] = useState(!passedBody);

  useEffect(() => {
    if (passedBody || !id) {
      setLoading(false);
      return;
    }

    async function load() {
      try {
        const creds = await getConversationCredentials();
        if (!creds) { setLoading(false); return; }

        // Login
        await fetch(`${creds.apiBaseUrl}/auth/login`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
          redirect: "follow",
        });

        if (type === "blog") {
          // Fetch blog post content
          const res = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${id}`, {
            headers: { Accept: "application/json" },
          });
          if (res.ok) {
            const posts = await res.json();
            if (Array.isArray(posts) && posts.length > 0) {
              const content = posts.map((p: Record<string, unknown>) =>
                stripHtml(String(p.content ?? ""))
              ).join("\n\n---\n\n");
              setBody(content);
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

  const icon = type === "blog" ? "📝" : type === "timeline" ? "🔔" : "📄";

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      <Text style={[styles.title, { color: theme.text }]}>
        {title || "(sans titre)"}
      </Text>

      <View style={styles.metaRow}>
        {from ? <Text style={[styles.from, { color: theme.accent }]}>{from}</Text> : null}
        {date ? <Text style={[styles.date, { color: theme.textTertiary }]}>{date}</Text> : null}
      </View>

      <View style={[styles.divider, { backgroundColor: theme.border }]} />

      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}

      {body ? (
        <Text style={[styles.body, { color: theme.text }]}>{body}</Text>
      ) : !loading ? (
        <Text style={[styles.empty, { color: theme.textTertiary }]}>
          Pas de contenu détaillé disponible.
        </Text>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  title: { fontSize: FontSize.xl, fontFamily: Fonts.bold, lineHeight: 28 },
  metaRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginTop: Spacing.sm },
  from: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, flex: 1 },
  date: { fontSize: FontSize.sm, fontFamily: Fonts.mono },
  divider: { height: 1, marginVertical: Spacing.md },
  body: { fontSize: FontSize.md, fontFamily: Fonts.regular, lineHeight: 24 },
  empty: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", marginTop: Spacing.xl },
});
