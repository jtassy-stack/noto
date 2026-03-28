import { useEffect, useState } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getGradesByChild } from "@/lib/database/repository";
import { gradeColor } from "@/constants/theme";
import { getConversationCredentials } from "@/lib/ent/conversation";
import type { Grade } from "@/types";

// --- Photo gallery for ENT children (replaces Notes tab) ---

function EntPhotoGallery() {
  const theme = useTheme();
  const [blogs, setBlogs] = useState<Array<{ id: string; title: string; postCount: number }>>([]);
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

        // Get post count for each blog
        const blogsWithCount = await Promise.all(
          data.map(async (b: Record<string, unknown>) => {
            const postsRes = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${b._id}`, {
              headers: { Accept: "application/json" },
            });
            const posts = postsRes.ok ? await postsRes.json() : [];
            return {
              id: String(b._id),
              title: String(b.title ?? "").trim(),
              postCount: Array.isArray(posts) ? posts.length : 0,
            };
          })
        );

        setBlogs(blogsWithCount);
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
        <Pressable
          key={blog.id}
          onPress={() => router.push({ pathname: "/gallery", params: { blogId: blog.id } })}
          style={[galleryStyles.albumCard, { backgroundColor: theme.surface, borderColor: theme.border }]}
        >
          <Text style={[galleryStyles.albumTitle, { color: theme.text }]}>{blog.title}</Text>
          <Text style={[galleryStyles.albumCount, { color: theme.textTertiary }]}>
            {blog.postCount} article{blog.postCount > 1 ? "s" : ""}
          </Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const galleryStyles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold },
  subtitle: { fontSize: FontSize.md, fontFamily: Fonts.regular, marginTop: Spacing.xs, marginBottom: Spacing.lg, color: "#888" },
  albumCard: { padding: Spacing.md, borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: Spacing.sm, gap: 4 },
  albumTitle: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold },
  albumCount: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
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
