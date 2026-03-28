import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { addFavorite, removeFavorite, getFavoritesByType } from "@/lib/database/repository";
import { stripHtml } from "@/lib/utils/html";

interface BlogEntry {
  id: string;
  title: string;
  postCount: number;
  authorName: string;
  isFav: boolean;
  isTeacher: boolean;
}

export function EntBlogScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [blogs, setBlogs] = useState<BlogEntry[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      const creds = await getConversationCredentials();
      if (!creds) { setLoading(false); return; }

      try {
        await fetch(`${creds.apiBaseUrl}/auth/login`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
          redirect: "follow",
        });

        const res = await fetch(`${creds.apiBaseUrl}/blog/list/all`, {
          headers: { Accept: "application/json" },
        });
        if (!res.ok) { setLoading(false); return; }
        const data = await res.json();
        if (!Array.isArray(data)) { setLoading(false); return; }

        // Get post count + author
        const blogsWithMeta = await Promise.all(
          data.map(async (b: Record<string, unknown>) => {
            const postsRes = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${b._id}`, {
              headers: { Accept: "application/json" },
            });
            const posts = postsRes.ok ? await postsRes.json() : [];
            const author = b.author as { username?: string } | undefined;
            return {
              id: String(b._id),
              title: String(b.title ?? "").trim(),
              postCount: Array.isArray(posts) ? posts.length : 0,
              authorName: author?.username ?? "",
            };
          })
        );

        // Filter teacher blogs
        const className = activeChild?.className ?? "";
        const teacherLastName = className.split(" - ").pop()?.replace(/^(M\.|Mme|M)\s*/i, "").trim().split(/\s+/).pop()?.toUpperCase() ?? "";

        const teacherBlogs = teacherLastName
          ? blogsWithMeta.filter(b => b.authorName.toUpperCase().includes(teacherLastName))
          : [];

        // Load favorites + auto-fav teacher blogs
        const favs = await getFavoritesByType("blog", activeChild?.id);
        const favIds = new Set(favs.map(f => f.id));

        for (const blog of teacherBlogs) {
          if (!favIds.has(blog.id)) {
            await addFavorite(blog.id, "blog", blog.title, activeChild?.id);
            favIds.add(blog.id);
          }
        }

        const teacherIds = new Set(teacherBlogs.map(b => b.id));
        const allBlogs: BlogEntry[] = [
          ...teacherBlogs.map(b => ({ ...b, isFav: true, isTeacher: true })),
          ...blogsWithMeta
            .filter(b => !teacherIds.has(b.id) && favIds.has(b.id))
            .map(b => ({ ...b, isFav: true, isTeacher: false })),
          ...blogsWithMeta
            .filter(b => !teacherIds.has(b.id) && !favIds.has(b.id))
            .map(b => ({ ...b, isFav: false, isTeacher: false })),
        ];

        setBlogs(allBlogs);
      } catch (e) {
        console.warn("[nōto] Blog list error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [activeChild]);

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}

      {!loading && blogs.length === 0 && (
        <Text style={[styles.empty, { color: theme.textTertiary }]}>Aucun blog.</Text>
      )}

      {blogs.map((blog) => (
        <View key={blog.id} style={[styles.card, { backgroundColor: theme.surface, borderColor: blog.isFav ? theme.accent : theme.border }]}>
          <Pressable
            onPress={() => router.push({ pathname: "/detail", params: { id: blog.id, title: blog.title, type: "blog" } })}
            style={styles.cardContent}
          >
            <Text style={[styles.cardTitle, { color: theme.text }]} numberOfLines={2}>{blog.title}</Text>
            <Text style={[styles.cardMeta, { color: theme.textTertiary }]}>
              {blog.postCount} article{blog.postCount > 1 ? "s" : ""}
              {blog.isTeacher ? "  ·  Prof de la classe" : ""}
            </Text>
          </Pressable>
          {!blog.isTeacher && (
            <Pressable
              onPress={async () => {
                if (blog.isFav) {
                  await removeFavorite(blog.id);
                } else {
                  await addFavorite(blog.id, "blog", blog.title, activeChild?.id);
                }
                setBlogs((prev) => prev.map((b) => b.id === blog.id ? { ...b, isFav: !b.isFav } : b));
              }}
              style={styles.favBtn}
            >
              <Text style={{ fontSize: 20 }}>{blog.isFav ? "⭐" : "☆"}</Text>
            </Pressable>
          )}
          {blog.isTeacher && <Text style={styles.teacherBadge}>⭐</Text>}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  empty: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", marginTop: Spacing.xl },
  card: { flexDirection: "row", alignItems: "center", borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: Spacing.sm, overflow: "hidden" },
  cardContent: { flex: 1, padding: Spacing.md, gap: 4 },
  cardTitle: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, lineHeight: 22 },
  cardMeta: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  favBtn: { padding: Spacing.md, justifyContent: "center", alignItems: "center" },
  teacherBadge: { fontSize: 20, paddingHorizontal: Spacing.md },
});
