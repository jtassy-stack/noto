import { useEffect, useState, useRef } from "react";
import { View, Text, Image, StyleSheet, FlatList, Dimensions, ActivityIndicator, Pressable } from "react-native";
import { useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getConversationCredentials } from "@/lib/ent/conversation";

const SCREEN_WIDTH = Dimensions.get("window").width;
const IMAGE_SIZE = (SCREEN_WIDTH - Spacing.lg * 2 - Spacing.xs * 2) / 3;

interface GalleryImage {
  id: string;
  url: string;
  base64?: string;
  postTitle: string;
}

export default function GalleryScreen() {
  const theme = useTheme();
  const { blogId } = useLocalSearchParams<{ blogId: string }>();

  const [images, setImages] = useState<GalleryImage[]>([]);
  const [loadedCount, setLoadedCount] = useState(0);
  const [totalCount, setTotalCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [selectedImage, setSelectedImage] = useState<string | null>(null);

  useEffect(() => {
    async function load() {
      if (!blogId) return;

      const creds = await getConversationCredentials();
      if (!creds) { setLoading(false); return; }

      try {
        // Login — all subsequent fetch() calls will have cookies
        await fetch(`${creds.apiBaseUrl}/auth/login`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
          redirect: "follow",
        });

        // Get all posts
        const postsRes = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${blogId}`, {
          headers: { Accept: "application/json" },
        });
        if (!postsRes.ok) { setLoading(false); return; }
        const posts = await postsRes.json() as Array<{ _id: string; title: string }>;

        // Collect all image URLs from all posts
        const allImages: GalleryImage[] = [];
        for (const post of posts) {
          const postRes = await fetch(`${creds.apiBaseUrl}/blog/post/${blogId}/${post._id}`, {
            headers: { Accept: "application/json" },
          });
          if (!postRes.ok) continue;

          const postData = await postRes.json() as { content?: string; title?: string };
          const content = postData.content ?? "";
          const imgRegex = /src="(\/workspace\/document\/[^"]+)"/g;
          let match;
          while ((match = imgRegex.exec(content)) !== null) {
            allImages.push({
              id: `${post._id}-${allImages.length}`,
              url: match[1]!,
              postTitle: String(postData.title ?? post.title ?? ""),
            });
          }
        }

        setTotalCount(allImages.length);
        console.log("[nōto] Gallery: found", allImages.length, "images");

        // Fetch images in batches of 4 (direct from ENT, no proxy)
        const BATCH = 4;
        for (let i = 0; i < allImages.length; i += BATCH) {
          const batch = allImages.slice(i, i + BATCH);
          const results = await Promise.allSettled(
            batch.map(async (img) => {
              const imgRes = await fetch(`${creds.apiBaseUrl}${img.url}`);
              if (!imgRes.ok) return img;
              const blob = await imgRes.blob();
              const base64 = await blobToBase64(blob);
              return { ...img, base64 };
            })
          );

          const loaded = results
            .filter((r): r is PromiseFulfilledResult<GalleryImage> => r.status === "fulfilled")
            .map((r) => r.value)
            .filter((img) => img.base64);

          setImages((prev) => [...prev, ...loaded]);
          setLoadedCount((prev) => prev + loaded.length);
        }
      } catch (e) {
        console.warn("[nōto] Gallery error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [blogId]);

  // Fullscreen viewer
  if (selectedImage) {
    return (
      <Pressable
        style={styles.fullscreen}
        onPress={() => setSelectedImage(null)}
      >
        <Image
          source={{ uri: selectedImage }}
          style={styles.fullscreenImage}
          resizeMode="contain"
        />
        <Text style={styles.closeHint}>Taper pour fermer</Text>
      </Pressable>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      {/* Progress */}
      <View style={styles.progressBar}>
        <Text style={[styles.countText, { color: theme.textSecondary }]}>
          {loading
            ? `Chargement... ${loadedCount}/${totalCount || "?"} photos`
            : `${images.length} photos`}
        </Text>
        {loading && <ActivityIndicator color={theme.accent} size="small" />}
      </View>

      {images.length > 0 && (
        <FlatList
          data={images}
          numColumns={3}
          keyExtractor={(item) => item.id}
          contentContainerStyle={styles.grid}
          columnWrapperStyle={styles.row}
          renderItem={({ item }) => (
            <Pressable onPress={() => item.base64 && setSelectedImage(item.base64)}>
              <Image
                source={{ uri: item.base64 }}
                style={[styles.thumbnail, { backgroundColor: theme.surface }]}
              />
            </Pressable>
          )}
        />
      )}

      {!loading && images.length === 0 && (
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Aucune photo.</Text>
      )}
    </View>
  );
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(reader.result as string);
    reader.readAsDataURL(blob);
  });
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  progressBar: { flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: Spacing.lg, paddingVertical: Spacing.sm },
  countText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  grid: { paddingHorizontal: Spacing.lg },
  row: { gap: Spacing.xs, marginBottom: Spacing.xs },
  thumbnail: { width: IMAGE_SIZE, height: IMAGE_SIZE, borderRadius: 4 },
  fullscreen: { flex: 1, justifyContent: "center", alignItems: "center", backgroundColor: "#000" },
  fullscreenImage: { width: "100%", height: "80%" },
  closeHint: { color: "#999", fontSize: 14, fontFamily: Fonts.regular, marginTop: Spacing.md },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", marginTop: Spacing.xxl },
});
