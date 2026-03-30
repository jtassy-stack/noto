import { useEffect, useState } from "react";
import { View, Text, ScrollView, Pressable, StyleSheet, ActivityIndicator, useColorScheme, Alert } from "react-native";
import { useLocalSearchParams, router } from "expo-router";
import { WebView } from "react-native-webview";
import { cacheDirectory, downloadAsync } from "expo-file-system/legacy";
import * as Sharing from "expo-sharing";
import FileViewer from "react-native-file-viewer";
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

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(reader.result as string);
    reader.readAsDataURL(blob);
  });
}

export default function DetailScreen() {
  const theme = useTheme();
  const scheme = useColorScheme();
  const { id, title, from, date, type, body: passedBody, blogId, postId } = useLocalSearchParams<{
    id: string;
    title: string;
    from: string;
    date: string;
    type: string; // "blog" | "blogpost" | "timeline"
    body: string;
    blogId: string;
    postId: string;
  }>();

  const [blogPosts, setBlogPosts] = useState<BlogPost[]>([]);
  const [htmlContent, setHtmlContent] = useState<string | null>(null);
  const [plainText, setPlainText] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [apiBaseUrl, setApiBaseUrl] = useState("");
  const [attachments, setAttachments] = useState<Array<{ url: string; name: string }>>([]);
  const [downloading, setDownloading] = useState<string | null>(null);

  async function downloadAndOpen(url: string, name: string) {
    setDownloading(url);
    try {
      const ext = name.includes(".") ? "" : ".pdf";
      const localUri = `${cacheDirectory}${name.replace(/[^a-zA-Z0-9._-]/g, "_")}${ext}`;

      const result = await downloadAsync(url, localUri);

      if (result.status !== 200) {
        Alert.alert("Erreur", "Impossible de télécharger le document.");
        return;
      }

      // Open with native viewer (Quick Look iOS / Intent Android)
      try {
        await FileViewer.open(result.uri, { showOpenWithDialog: true });
      } catch {
        // Fallback to share sheet
        if (await Sharing.isAvailableAsync()) {
          await Sharing.shareAsync(result.uri, {
            mimeType: result.headers["content-type"] || "application/octet-stream",
            dialogTitle: name,
          });
        }
      }
    } catch (e) {
      console.warn("[nōto] Document download error:", e);
      Alert.alert("Erreur", "Impossible de télécharger le document.");
    } finally {
      setDownloading(null);
    }
  }

  useEffect(() => {
    async function load() {
      console.log("[nōto] Detail screen:", { id, type, blogId, postId, hasBody: !!passedBody, title });

      // Timeline — plain text
      if (type === "timeline" && passedBody) {
        setPlainText(stripHtml(passedBody));
        setLoading(false);
        return;
      }

      // Schoolbook (carnet de liaison) — HTML with possible document links
      if (type === "schoolbook" && passedBody) {
        const creds = await getConversationCredentials();
        if (creds) {
          setApiBaseUrl(creds.apiBaseUrl);

          // Login to get auth cookies for document fetching
          await fetch(`${creds.apiBaseUrl}/auth/login`, {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
            redirect: "follow",
          });

          // Extract document links and inline images with auth
          let html = passedBody;

          // Convert relative image URLs to base64 (images need auth)
          const imgRegex = /src="(\/workspace\/document\/[^"]+)"/g;
          const imgMatches = [...html.matchAll(imgRegex)];
          for (const match of imgMatches) {
            try {
              const imgRes = await fetch(`${creds.apiBaseUrl}${match[1]}`);
              if (imgRes.ok) {
                const blob = await imgRes.blob();
                const base64 = await blobToBase64(blob);
                html = html.replace(match[0], `src="${base64}"`);
              }
            } catch {}
          }

          // Extract document download links for the attachment bar
          const docRegex = /href="(\/workspace\/document\/[^"]+)"/g;
          const docMatches = [...html.matchAll(docRegex)];
          const docs: Array<{ url: string; name: string }> = [];
          for (const match of docMatches) {
            const docPath = match[1]!;
            const fullUrl = `${creds.apiBaseUrl}${docPath}`;

            // Resolve actual filename via HEAD request (Content-Disposition header)
            let fileName = "";
            try {
              const headRes = await fetch(fullUrl, { method: "HEAD" });
              const disposition = headRes.headers.get("content-disposition") ?? "";
              // Parse: attachment; filename="document.pdf" or filename*=UTF-8''document.pdf
              const fnMatch = disposition.match(/filename\*?=(?:UTF-8''|"?)([^";\n]+)/i);
              if (fnMatch) {
                fileName = decodeURIComponent(fnMatch[1]!.trim().replace(/^"|"$/g, ""));
              }
              // Fallback: try Content-Type to guess extension
              if (!fileName) {
                const ct = headRes.headers.get("content-type") ?? "";
                const extMap: Record<string, string> = {
                  "application/pdf": "document.pdf",
                  "image/jpeg": "image.jpg",
                  "image/png": "image.png",
                  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "document.docx",
                  "application/msword": "document.doc",
                };
                fileName = extMap[ct] ?? "";
              }
            } catch {}

            // Last fallback: extract from link text in HTML
            if (!fileName) {
              const linkTextRegex = new RegExp(
                `href="${docPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"[^>]*>([\\s\\S]*?)</a>`,
                "i"
              );
              const linkMatch = html.match(linkTextRegex);
              if (linkMatch) {
                fileName = stripHtml(linkMatch[1]!).trim();
              }
            }

            docs.push({
              url: fullUrl,
              name: fileName || docPath.split("/").pop() || "Document",
            });
          }
          if (docs.length > 0) setAttachments(docs);

          setHtmlContent(html);
        } else {
          setHtmlContent(passedBody);
        }
        setLoading(false);
        return;
      }

      if (!id && !blogId) { setLoading(false); return; }

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
          // Fetch blog posts list
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
        } else if (type === "blogpost" && blogId && postId) {
          // Fetch blog post content
          console.log("[nōto] Fetching blog post:", blogId, postId);
          const postRes = await fetch(`${creds.apiBaseUrl}/blog/post/${blogId}/${postId}`, {
            headers: { Accept: "application/json" },
          });

          if (postRes.ok) {
            const post = await postRes.json() as Record<string, unknown>;
            let content = String(post.content ?? "");

            // Convert image URLs to base64 data URIs (images need auth cookies)
            const imgRegex = /src="(\/workspace\/document\/[^"]+)"/g;
            const matches = [...content.matchAll(imgRegex)];

            for (const match of matches) {
              try {
                const imgUrl = match[1]!;
                const imgRes = await fetch(`${creds.apiBaseUrl}${imgUrl}`);
                if (imgRes.ok) {
                  const blob = await imgRes.blob();
                  const base64 = await blobToBase64(blob);
                  content = content.replace(match[0], `src="${base64}"`);
                }
              } catch {
                // Skip failed images
              }
            }

            console.log("[nōto] Post content with", matches.length, "images inlined");
            setHtmlContent(content);
          }
        }
      } catch (e) {
        console.warn("[nōto] Detail fetch error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, type, passedBody, blogId, postId]);

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
        <Pressable
          onPress={() => router.push({
            pathname: "/gallery",
            params: { blogId: id, blogTitle: title },
          })}
          style={[styles.galleryBtn, { backgroundColor: theme.accent }]}
        >
          <Text style={styles.galleryBtnText}>📸 Voir toutes les photos</Text>
        </Pressable>

        {blogPosts.map((post) => (
          <Pressable
            key={post.id}
            onPress={() => router.push({
              pathname: "/detail",
              params: { id: post.id, title: post.title, date: post.date, type: "blogpost", blogId: id, postId: post.id },
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

  // Rich HTML content (blog post with inline images, formatted messages): WebView
  if (htmlContent) {
    return (
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <View style={styles.header}>
          <Text style={[styles.title, { color: theme.text }]}>{title}</Text>
          {from ? <Text style={[styles.from, { color: theme.accent }]}>{from}</Text> : null}
          {date ? <Text style={[styles.date, { color: theme.textTertiary }]}>{date}</Text> : null}
          <View style={[styles.divider, { backgroundColor: theme.border }]} />
        </View>

        {/* Attachment bar */}
        {attachments.length > 0 && (
          <View style={styles.attachmentBar}>
            {attachments.map((doc) => (
              <Pressable
                key={doc.url}
                style={({ pressed }) => [
                  styles.attachmentChip,
                  { backgroundColor: theme.surfaceElevated, borderColor: theme.border, opacity: pressed ? 0.6 : 1 },
                ]}
                onPress={() => downloadAndOpen(doc.url, doc.name)}
                disabled={downloading === doc.url}
              >
                {downloading === doc.url ? (
                  <ActivityIndicator size="small" color={theme.accent} />
                ) : (
                  <Text style={[styles.attachmentIcon, { color: theme.accent }]}>&#x1F4CE;</Text>
                )}
                <Text style={[styles.attachmentName, { color: theme.text }]} numberOfLines={1}>
                  {doc.name}
                </Text>
              </Pressable>
            ))}
          </View>
        )}

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
  galleryBtn: { borderRadius: BorderRadius.md, paddingVertical: 14, alignItems: "center", marginBottom: Spacing.lg },
  galleryBtnText: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
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
  attachmentBar: { paddingHorizontal: Spacing.lg, gap: 6, marginBottom: Spacing.sm },
  attachmentChip: {
    flexDirection: "row", alignItems: "center", gap: 8,
    paddingHorizontal: 12, paddingVertical: 10,
    borderRadius: BorderRadius.md, borderWidth: 1,
  },
  attachmentIcon: { fontSize: 16 },
  attachmentName: { fontSize: FontSize.sm, fontFamily: Fonts.medium, flex: 1 },
});
