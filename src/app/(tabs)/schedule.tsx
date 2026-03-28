import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getScheduleByChild } from "@/lib/database/repository";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { stripHtml } from "@/lib/utils/html";
import type { ScheduleEntry } from "@/types";

// --- Blog list for ENT children (replaces EDT tab) ---

interface BlogEntry {
  id: string;
  title: string;
  postCount: number;
  authorName: string;
}

interface BlogPostEntry {
  id: string;
  blogId: string;
  title: string;
  date: string;
  preview: string;
}

function EntBlogScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [posts, setPosts] = useState<BlogPostEntry[]>([]);
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

        // Get all blogs
        const blogsRes = await fetch(`${creds.apiBaseUrl}/blog/list/all`, {
          headers: { Accept: "application/json" },
        });
        if (!blogsRes.ok) { setLoading(false); return; }
        const blogs = await blogsRes.json() as Array<Record<string, unknown>>;

        // Filter by teacher
        const className = activeChild?.className ?? "";
        const teacherLastName = className.split(" - ").pop()?.replace(/^(M\.|Mme|M)\s*/i, "").trim().split(/\s+/).pop()?.toUpperCase() ?? "";

        const teacherBlogs = teacherLastName
          ? blogs.filter(b => {
              const author = b.author as { username?: string } | undefined;
              return author?.username?.toUpperCase().includes(teacherLastName);
            })
          : blogs;

        // Get recent posts from teacher blogs
        const allPosts: BlogPostEntry[] = [];
        for (const blog of teacherBlogs) {
          const blogId = String(blog._id);
          const postsRes = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${blogId}`, {
            headers: { Accept: "application/json" },
          });
          if (!postsRes.ok) continue;

          const blogPosts = await postsRes.json() as Array<Record<string, unknown>>;
          for (const p of blogPosts.slice(0, 10)) {
            const created = p.created as { $date?: string } | undefined;
            const dateStr = created?.$date
              ? new Date(created.$date).toLocaleDateString("fr-FR", { day: "numeric", month: "long" })
              : "";

            // Fetch post content for preview
            const postRes = await fetch(`${creds.apiBaseUrl}/blog/post/${blogId}/${p._id}`, {
              headers: { Accept: "application/json" },
            });
            let preview = "";
            if (postRes.ok) {
              const postData = await postRes.json() as { content?: string };
              preview = stripHtml(postData.content ?? "").substring(0, 100);
            }

            allPosts.push({
              id: String(p._id),
              blogId,
              title: String(p.title ?? ""),
              date: dateStr,
              preview,
            });
          }
        }

        // Sort by date (newest first)
        allPosts.sort((a, b) => b.date.localeCompare(a.date));
        setPosts(allPosts);
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
      style={[blogStyles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={blogStyles.content}
    >
      <Text style={[blogStyles.title, { color: theme.text }]}>📝 Blog</Text>

      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}

      {!loading && posts.length === 0 && (
        <Text style={[blogStyles.empty, { color: theme.textTertiary }]}>Aucun article.</Text>
      )}

      {posts.map((post) => (
        <Pressable
          key={post.id}
          onPress={() => router.push({
            pathname: "/detail",
            params: { id: post.id, title: post.title, date: post.date, type: "blogpost", blogId: post.blogId, postId: post.id },
          })}
          style={[blogStyles.postCard, { backgroundColor: theme.surface, borderColor: theme.border }]}
        >
          <Text style={[blogStyles.postTitle, { color: theme.text }]} numberOfLines={2}>
            {post.title}
          </Text>
          <Text style={[blogStyles.postDate, { color: theme.textTertiary }]}>{post.date}</Text>
          {post.preview ? (
            <Text style={[blogStyles.postPreview, { color: theme.textSecondary }]} numberOfLines={2}>
              {post.preview}
            </Text>
          ) : null}
        </Pressable>
      ))}
    </ScrollView>
  );
}

const blogStyles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold, marginBottom: Spacing.lg },
  empty: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", marginTop: Spacing.xl },
  postCard: { padding: Spacing.md, borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: Spacing.sm, gap: 4 },
  postTitle: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, lineHeight: 22 },
  postDate: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  postPreview: { fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 18 },
});

const DAY_LABELS = ["D", "L", "M", "Me", "J", "V", "S"];

function getDateForOffset(offset: number): Date {
  const d = new Date();
  d.setDate(d.getDate() + offset);
  d.setHours(0, 0, 0, 0);
  return d;
}

export default function ScheduleScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [dayOffset, setDayOffset] = useState(0);
  const [schedule, setSchedule] = useState<ScheduleEntry[]>([]);

  useEffect(() => {
    if (!activeChild) return;

    const day = getDateForOffset(dayOffset);
    const nextDay = getDateForOffset(dayOffset + 1);

    getScheduleByChild(
      activeChild.id,
      day.toISOString(),
      nextDay.toISOString()
    ).then(setSchedule);
  }, [activeChild, dayOffset]);

  // ENT child → show blog
  if (activeChild?.source === "ent" && !activeChild.hasSchedule) {
    return <EntBlogScreen />;
  }

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Connectez un compte.</Text>
      </View>
    );
  }

  // Build day tabs: today ± 2 days (5 days visible)
  const dayTabs = [-2, -1, 0, 1, 2].map((offset) => {
    const d = getDateForOffset(offset);
    return {
      offset,
      label: DAY_LABELS[d.getDay()]!,
      date: d.getDate(),
      isToday: offset === 0,
    };
  });

  const selectedDate = getDateForOffset(dayOffset);
  const dateStr = selectedDate.toLocaleDateString("fr-FR", {
    weekday: "long",
    day: "numeric",
    month: "long",
  });

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {/* Day selector */}
      <View style={styles.dayTabs}>
        {dayTabs.map((d) => {
          const active = d.offset === dayOffset;
          return (
            <Pressable
              key={d.offset}
              onPress={() => setDayOffset(d.offset)}
              style={[
                styles.dayTab,
                {
                  backgroundColor: active ? theme.accent : theme.surfaceElevated,
                  borderColor: active ? theme.accent : theme.border,
                },
              ]}
            >
              <Text
                style={[
                  styles.dayLabel,
                  { color: active ? "#FFFFFF" : theme.textSecondary },
                ]}
              >
                {d.label}
              </Text>
              <Text
                style={[
                  styles.dayDate,
                  {
                    color: active ? "#FFFFFF" : theme.text,
                    fontFamily: active ? Fonts.bold : Fonts.regular,
                  },
                ]}
              >
                {d.date}
              </Text>
            </Pressable>
          );
        })}
      </View>

      <Text style={[styles.dateLabel, { color: theme.textSecondary }]}>
        {dateStr}
      </Text>

      {/* Timeline */}
      {schedule.length === 0 && (
        <Text style={[styles.emptyText, { color: theme.textTertiary, marginTop: Spacing.xl }]}>
          Aucun cours ce jour.
        </Text>
      )}

      {schedule.map((s, i) => {
        const startTime = new Date(s.startTime).toLocaleTimeString("fr-FR", {
          hour: "2-digit",
          minute: "2-digit",
        });
        const endTime = new Date(s.endTime).toLocaleTimeString("fr-FR", {
          hour: "2-digit",
          minute: "2-digit",
        });

        return (
          <View key={s.id} style={styles.slot}>
            {/* Time column */}
            <View style={styles.timeCol}>
              <Text style={[styles.startTime, { color: s.isCancelled ? theme.crimson : theme.accent }]}>
                {startTime}
              </Text>
              <Text style={[styles.endTime, { color: theme.textTertiary }]}>
                {endTime}
              </Text>
            </View>

            {/* Divider */}
            <View
              style={[
                styles.divider,
                {
                  backgroundColor: s.isCancelled ? theme.crimson : theme.accent,
                  opacity: s.isCancelled ? 0.5 : 0.3,
                },
              ]}
            />

            {/* Content */}
            <View style={styles.slotContent}>
              <Text
                style={[
                  styles.slotSubject,
                  {
                    color: s.isCancelled ? theme.crimson : theme.text,
                    textDecorationLine: s.isCancelled ? "line-through" : "none",
                  },
                ]}
              >
                {s.subject}
              </Text>
              <Text
                style={[
                  styles.slotMeta,
                  { color: s.isCancelled ? theme.crimson : theme.textSecondary, opacity: s.isCancelled ? 0.5 : 1 },
                ]}
              >
                {[s.teacher, s.room].filter(Boolean).join(" · ")}
              </Text>
              {s.isCancelled && (
                <View style={[styles.cancelBadge, { backgroundColor: theme.crimson }]}>
                  <Text style={styles.cancelText}>ANNULÉ</Text>
                </View>
              )}
              {s.status && !s.isCancelled && (
                <Text style={[styles.statusText, { color: theme.accent }]}>
                  {s.status}
                </Text>
              )}
            </View>
          </View>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  empty: { flex: 1, justifyContent: "center", alignItems: "center", padding: Spacing.lg },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center" },

  dayTabs: { flexDirection: "row", gap: 4, marginBottom: Spacing.md },
  dayTab: {
    flex: 1,
    alignItems: "center",
    paddingVertical: 10,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    gap: 2,
  },
  dayLabel: { fontSize: FontSize.xs, fontFamily: Fonts.medium },
  dayDate: { fontSize: FontSize.lg, fontFamily: Fonts.regular },
  dateLabel: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    marginBottom: Spacing.md,
    textTransform: "capitalize",
  },

  slot: { flexDirection: "row", paddingVertical: 14, gap: 14 },
  timeCol: { width: 46, gap: 2 },
  startTime: { fontSize: FontSize.sm, fontFamily: Fonts.mono },
  endTime: { fontSize: FontSize.xs, fontFamily: Fonts.mono },
  divider: { width: 2, borderRadius: 1, alignSelf: "stretch" },
  slotContent: { flex: 1, gap: 3 },
  slotSubject: { fontSize: FontSize.md, fontFamily: Fonts.semiBold },
  slotMeta: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  cancelBadge: {
    alignSelf: "flex-start",
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 4,
    opacity: 0.2,
    marginTop: 2,
  },
  cancelText: { fontSize: 10, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  statusText: { fontSize: FontSize.xs, fontFamily: Fonts.medium, marginTop: 2 },
});
