import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getGradesByChild } from "@/lib/database/repository";
import { gradeColor } from "@/constants/theme";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { addFavorite, removeFavorite, getFavoritesByType } from "@/lib/database/repository";
import type { Grade } from "@/types";

// --- Photo gallery for ENT children (replaces Notes tab) ---

function EntPhotoGallery() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [blogs, setBlogs] = useState<Array<{ id: string; title: string; postCount: number; isFav: boolean }>>([]);
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

        // Get post count + author for each blog
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

        // Filter by matching blog author with child's teacher
        const className = activeChild?.className ?? "";
        // Extract teacher name: "Céline DESBATS" from "MS - Mme Céline DESBATS"
        const classParts = className.split(" - ");
        const teacherPart = classParts[classParts.length - 1]?.replace(/^(M\.|Mme|M)\s*/i, "").trim() ?? "";
        // Extract last name from teacher: "DESBATS" from "Céline DESBATS", "TOLOTTA" from "Lucas TOLOTTA"
        const teacherLastName = teacherPart.split(/\s+/).pop()?.toUpperCase() ?? "";

        const filtered = teacherLastName
          ? blogsWithMeta.filter((b) => {
              // Match author last name with teacher last name
              if (teacherLastName && b.authorName.toUpperCase().includes(teacherLastName)) return true;
              // Fallback: match class short name in title
              const classShort = classParts.length > 2
                ? classParts.slice(0, -1).join(" - ").trim()
                : classParts[0]?.trim() ?? "";
              if (classShort && b.title.toUpperCase().includes(classShort.toUpperCase())) return true;
              return false;
            })
          : blogsWithMeta;

        // Load favorites and merge
        const favs = await getFavoritesByType("blog", activeChild?.id);
        const favIds = new Set(favs.map(f => f.id));

        // Add favorited blogs that weren't in filtered list
        const favBlogs = blogsWithMeta
          .filter(b => favIds.has(b.id) && !filtered.some(f => f.id === b.id))
          .map(b => ({ ...b, isFav: true }));

        const allBlogs = [
          ...filtered.map(b => ({ ...b, isFav: favIds.has(b.id) })),
          ...favBlogs,
        ].sort((a, b) => (a.isFav === b.isFav ? 0 : a.isFav ? -1 : 1)); // Favs first

        console.log("[nōto] Blogs:", blogsWithMeta.length, "total →", allBlogs.length, "for", activeChild?.firstName, "(teacher:", teacherLastName, ", favs:", favBlogs.length, ")");
        setBlogs(allBlogs);
      } catch (e) {
        console.warn("[nōto] Blog list error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  return (
    <ScrollView
      style={[galleryStyles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={galleryStyles.content}
    >
      <Text style={[galleryStyles.title, { color: theme.text }]}>📸 Photos</Text>
      <Text style={[galleryStyles.subtitle, { color: theme.textSecondary }]}>
        Albums de la classe
      </Text>

      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}

      {blogs.map((blog) => (
        <View key={blog.id} style={[galleryStyles.albumCard, { backgroundColor: theme.surface, borderColor: blog.isFav ? theme.accent : theme.border }]}>
          <Pressable
            onPress={() => router.push({ pathname: "/gallery", params: { blogId: blog.id } })}
            style={galleryStyles.albumContent}
          >
            <Text style={[galleryStyles.albumTitle, { color: theme.text }]}>{blog.title}</Text>
            <Text style={[galleryStyles.albumCount, { color: theme.textTertiary }]}>
              {blog.postCount} article{blog.postCount > 1 ? "s" : ""}
            </Text>
          </Pressable>
          <Pressable
            onPress={async () => {
              if (blog.isFav) {
                await removeFavorite(blog.id);
              } else {
                await addFavorite(blog.id, "blog", blog.title, activeChild?.id);
              }
              setBlogs((prev) => prev.map((b) => b.id === blog.id ? { ...b, isFav: !b.isFav } : b)
                .sort((a, b) => (a.isFav === b.isFav ? 0 : a.isFav ? -1 : 1)));
            }}
            style={galleryStyles.favBtn}
          >
            <Text style={{ fontSize: 20 }}>{blog.isFav ? "⭐" : "☆"}</Text>
          </Pressable>
        </View>
      ))}
    </ScrollView>
  );
}

const galleryStyles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold },
  subtitle: { fontSize: FontSize.md, fontFamily: Fonts.regular, marginTop: Spacing.xs, marginBottom: Spacing.lg, color: "#888" },
  albumCard: { flexDirection: "row", alignItems: "center", borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: Spacing.sm, overflow: "hidden" },
  albumContent: { flex: 1, padding: Spacing.md, gap: 4 },
  albumTitle: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold },
  albumCount: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  favBtn: { padding: Spacing.md, justifyContent: "center", alignItems: "center" },
});

// --- Grades screen ---

interface SubjectAvg {
  subject: string;
  average: number;
  count: number;
}

export default function GradesScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [grades, setGrades] = useState<Grade[]>([]);

  useEffect(() => {
    if (!activeChild) return;
    getGradesByChild(activeChild.id).then(setGrades);
  }, [activeChild]);

  // ENT child without grades → show photo gallery
  if (activeChild?.source === "ent" && !activeChild.hasGrades) {
    return <EntPhotoGallery />;
  }

  if (!activeChild) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Connectez un compte.</Text>
      </View>
    );
  }

  if (grades.length === 0) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Aucune note pour le moment. Synchronisez depuis l'accueil.
        </Text>
      </View>
    );
  }

  // Compute subject averages
  const subjectMap = new Map<string, { total: number; count: number }>();
  for (const g of grades) {
    const normalized = (g.value / g.outOf) * 20;
    const existing = subjectMap.get(g.subject) ?? { total: 0, count: 0 };
    existing.total += normalized;
    existing.count += 1;
    subjectMap.set(g.subject, existing);
  }

  const subjectAverages: SubjectAvg[] = Array.from(subjectMap.entries())
    .map(([subject, { total, count }]) => ({
      subject,
      average: total / count,
      count,
    }))
    .sort((a, b) => b.average - a.average);

  // General average
  const generalAvg =
    subjectAverages.reduce((sum, s) => sum + s.average, 0) / subjectAverages.length;

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {/* General average card */}
      <View style={[styles.avgCard, { backgroundColor: theme.surface, borderColor: theme.accent }]}>
        <Text style={[styles.avgLabel, { color: theme.textSecondary }]}>
          MOYENNE GÉNÉRALE
        </Text>
        <Text style={[styles.avgValue, { color: theme.accent }]}>
          {generalAvg.toFixed(1)}
        </Text>
        <Text style={[styles.avgSub, { color: theme.textTertiary }]}>
          {subjectAverages.length} matières · {grades.length} notes
        </Text>
      </View>

      {/* Subject bars */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>
        PAR MATIÈRE
      </Text>
      {subjectAverages.map((s) => {
        const color = gradeColor(s.average, 20, theme);
        const pct = Math.min(s.average / 20, 1);
        return (
          <View key={s.subject} style={styles.barRow}>
            <View style={styles.barLabelRow}>
              <Text style={[styles.barSubject, { color: theme.text }]}>
                {s.subject}
              </Text>
              <Text style={[styles.barValue, { color }]}>
                {s.average.toFixed(1)}
              </Text>
            </View>
            <View style={[styles.barBg, { backgroundColor: theme.surfaceElevated }]}>
              <View
                style={[styles.barFill, { width: `${pct * 100}%`, backgroundColor: color }]}
              />
            </View>
          </View>
        );
      })}

      {/* Recent grades list */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.lg }]}>
        DERNIÈRES NOTES
      </Text>
      {grades.slice(0, 15).map((g) => (
        <View
          key={g.id}
          style={[styles.gradeRow, { backgroundColor: theme.surface, borderColor: theme.border }]}
        >
          <View style={styles.gradeInfo}>
            <Text style={[styles.gradeSubject, { color: theme.text }]}>{g.subject}</Text>
            <Text style={[styles.gradeMeta, { color: theme.textTertiary }]}>
              {g.date}{g.comment ? ` · ${g.comment}` : ""}
            </Text>
          </View>
          <Text style={[styles.gradeValue, { color: gradeColor(g.value, g.outOf, theme) }]}>
            {g.value}/{g.outOf}
          </Text>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  empty: { flex: 1, justifyContent: "center", alignItems: "center", padding: Spacing.lg },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center" },

  avgCard: {
    alignItems: "center",
    padding: Spacing.lg,
    borderRadius: BorderRadius.lg,
    borderWidth: 1,
    marginBottom: Spacing.lg,
    gap: 4,
  },
  avgLabel: { fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5 },
  avgValue: { fontSize: 36, fontFamily: Fonts.monoBold },
  avgSub: { fontSize: FontSize.sm, fontFamily: Fonts.regular },

  sectionLabel: {
    fontSize: 11,
    fontFamily: Fonts.medium,
    letterSpacing: 1.5,
    marginBottom: Spacing.sm,
  },

  barRow: { marginBottom: Spacing.md },
  barLabelRow: { flexDirection: "row", justifyContent: "space-between", marginBottom: 4 },
  barSubject: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  barValue: { fontSize: FontSize.md, fontFamily: Fonts.monoBold },
  barBg: { height: 4, borderRadius: 2, overflow: "hidden" },
  barFill: { height: 4, borderRadius: 2 },

  gradeRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    padding: 12,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: 4,
  },
  gradeInfo: { flex: 1, gap: 2 },
  gradeSubject: { fontSize: FontSize.md, fontFamily: Fonts.medium },
  gradeMeta: { fontSize: FontSize.xs, fontFamily: Fonts.regular },
  gradeValue: { fontSize: FontSize.lg, fontFamily: Fonts.monoBold },
});
