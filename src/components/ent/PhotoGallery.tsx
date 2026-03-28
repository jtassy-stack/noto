import { useEffect, useState } from "react";
import { View, Text, Image, StyleSheet, FlatList, Dimensions, ActivityIndicator, Pressable, ScrollView } from "react-native";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getConversationCredentials } from "@/lib/ent/conversation";
import { getFavoritesByType } from "@/lib/database/repository";

const SCREEN_WIDTH = Dimensions.get("window").width;
const IMAGE_SIZE = (SCREEN_WIDTH - Spacing.lg * 2 - Spacing.xs * 2) / 3;

interface PhotoItem {
  id: string;
  url: string;
  source: string;
  sourceId: string;
  base64?: string;
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(reader.result as string);
    reader.readAsDataURL(blob);
  });
}

export function EntPhotoGallery() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const [photos, setPhotos] = useState<PhotoItem[]>([]);
  const [sources, setSources] = useState<string[]>([]);
  const [activeFilter, setActiveFilter] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingImages, setLoadingImages] = useState(false);
  const [loadedCount, setLoadedCount] = useState(0);
  const [selectedImage, setSelectedImage] = useState<string | null>(null);

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

        const allPhotos: PhotoItem[] = [];
        const sourceNames = new Set<string>();

        // Photos from FAVORITED blogs only
        const favs = await getFavoritesByType("blog", activeChild?.id);

        for (const fav of favs) {
          const postsRes = await fetch(`${creds.apiBaseUrl}/blog/post/list/all/${fav.id}`, {
            headers: { Accept: "application/json" },
          });
          if (!postsRes.ok) continue;
          const posts = await postsRes.json() as Array<{ _id: string }>;

          for (const post of posts) {
            const postRes = await fetch(`${creds.apiBaseUrl}/blog/post/${fav.id}/${post._id}`, {
              headers: { Accept: "application/json" },
            });
            if (!postRes.ok) continue;
            const postData = await postRes.json() as { content?: string };
            const content = postData.content ?? "";
            const imgRegex = /src="(\/workspace\/document\/[^"]+)"/g;
            let match;
            while ((match = imgRegex.exec(content)) !== null) {
              allPhotos.push({ id: `${post._id}-${allPhotos.length}`, url: match[1]!, source: fav.title, sourceId: fav.id });
            }
          }
          if (allPhotos.some(p => p.sourceId === fav.id)) sourceNames.add(fav.title);
        }

        // Photos from messages
        try {
          const msgRes = await fetch(`${creds.apiBaseUrl}/conversation/list/INBOX?page=0&pageSize=20`, {
            headers: { Accept: "application/json" },
          });
          if (msgRes.ok) {
            const msgs = await msgRes.json() as Array<{ id: string }>;
            for (const msg of msgs) {
              const msgDetail = await fetch(`${creds.apiBaseUrl}/conversation/message/${msg.id}`, { headers: { Accept: "application/json" } });
              if (!msgDetail.ok) continue;
              const msgData = await msgDetail.json() as { body?: string };
              if (!msgData.body) continue;
              const imgRegex = /src="(\/workspace\/document\/[^"]+)"/g;
              let match;
              while ((match = imgRegex.exec(msgData.body)) !== null) {
                allPhotos.push({ id: `msg-${msg.id}-${allPhotos.length}`, url: match[1]!, source: "Messages", sourceId: "messages" });
              }
            }
            if (allPhotos.some(p => p.source === "Messages")) sourceNames.add("Messages");
          }
        } catch {}

        console.log("[nōto] Gallery:", allPhotos.length, "photos,", sourceNames.size, "sources");
        setPhotos(allPhotos);
        setSources(Array.from(sourceNames));
        setLoading(false);

        // Load images in batches
        if (allPhotos.length > 0) {
          setLoadingImages(true);
          const BATCH = 4;
          for (let i = 0; i < allPhotos.length; i += BATCH) {
            const batch = allPhotos.slice(i, i + BATCH);
            const results = await Promise.allSettled(
              batch.map(async (photo) => {
                const imgRes = await fetch(`${creds.apiBaseUrl}${photo.url}`);
                if (!imgRes.ok) return null;
                const blob = await imgRes.blob();
                return { id: photo.id, base64: await blobToBase64(blob) };
              })
            );

            setPhotos(prev => {
              const updated = [...prev];
              for (const r of results) {
                if (r.status === "fulfilled" && r.value) {
                  const idx = updated.findIndex(p => p.id === r.value!.id);
                  if (idx >= 0) updated[idx] = { ...updated[idx]!, base64: r.value.base64 };
                }
              }
              return updated;
            });
            setLoadedCount(prev => prev + batch.length);
          }
          setLoadingImages(false);
        }
      } catch (e) {
        console.warn("[nōto] Gallery error:", e);
        setLoading(false);
      }
    }
    load();
  }, [activeChild]);

  const filteredPhotos = activeFilter ? photos.filter(p => p.source === activeFilter) : photos;

  if (selectedImage) {
    return (
      <Pressable style={styles.fullscreen} onPress={() => setSelectedImage(null)}>
        <Image source={{ uri: selectedImage }} style={styles.fullscreenImage} resizeMode="contain" />
        <Text style={styles.closeHint}>Taper pour fermer</Text>
      </Pressable>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <View style={styles.headerRow}>
        <Text style={[styles.countText, { color: theme.textSecondary }]}>
          {loading ? "Chargement..." : `${filteredPhotos.length} photos`}
        </Text>
        {loadingImages && (
          <Text style={[styles.progressText, { color: theme.textTertiary }]}>
            {loadedCount}/{photos.length}
          </Text>
        )}
      </View>

      {sources.length > 1 && (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.filterScroll} contentContainerStyle={styles.filterRow}>
          <Pressable
            onPress={() => setActiveFilter(null)}
            style={[styles.chip, { backgroundColor: !activeFilter ? theme.accent : theme.surfaceElevated }]}
          >
            <Text style={[styles.chipText, { color: !activeFilter ? "#FFF" : theme.text }]}>Tout</Text>
          </Pressable>
          {sources.map(s => (
            <Pressable
              key={s}
              onPress={() => setActiveFilter(activeFilter === s ? null : s)}
              style={[styles.chip, { backgroundColor: activeFilter === s ? theme.accent : theme.surfaceElevated }]}
            >
              <Text style={[styles.chipText, { color: activeFilter === s ? "#FFF" : theme.text }]} numberOfLines={1}>
                {s === "Messages" ? "📬 Messages" : `📝 ${s}`}
              </Text>
            </Pressable>
          ))}
        </ScrollView>
      )}

      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xxl }} size="large" />}

      {!loading && filteredPhotos.length === 0 && (
        <Text style={[styles.empty, { color: theme.textTertiary }]}>
          {photos.length === 0 ? "Aucune photo.\nFavorisez un blog pour voir ses photos ici." : "Aucune photo pour ce filtre."}
        </Text>
      )}

      {filteredPhotos.length > 0 && (
        <FlatList
          data={filteredPhotos}
          numColumns={3}
          keyExtractor={item => item.id}
          contentContainerStyle={styles.grid}
          columnWrapperStyle={styles.row}
          renderItem={({ item }) => (
            <Pressable onPress={() => item.base64 && setSelectedImage(item.base64)}>
              {item.base64 ? (
                <Image source={{ uri: item.base64 }} style={[styles.thumb, { backgroundColor: theme.surface }]} />
              ) : (
                <View style={[styles.thumb, { backgroundColor: theme.surface, justifyContent: "center", alignItems: "center" }]}>
                  <ActivityIndicator color={theme.textTertiary} size="small" />
                </View>
              )}
            </Pressable>
          )}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  headerRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", paddingHorizontal: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xs },
  countText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  progressText: { fontSize: FontSize.xs, fontFamily: Fonts.mono },
  filterScroll: { maxHeight: 44, paddingLeft: Spacing.lg, marginBottom: Spacing.sm },
  filterRow: { gap: Spacing.xs, paddingRight: Spacing.lg },
  chip: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: 20 },
  chipText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },
  grid: { paddingHorizontal: Spacing.lg },
  row: { gap: Spacing.xs, marginBottom: Spacing.xs },
  thumb: { width: IMAGE_SIZE, height: IMAGE_SIZE, borderRadius: 4 },
  fullscreen: { flex: 1, justifyContent: "center", alignItems: "center", backgroundColor: "#000" },
  fullscreenImage: { width: "100%", height: "80%" },
  closeHint: { color: "#999", fontSize: 14, fontFamily: Fonts.regular, marginTop: Spacing.md },
  empty: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", marginTop: Spacing.xxl, lineHeight: 22, paddingHorizontal: Spacing.lg },
});
