import { useEffect, useState, useCallback } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator, RefreshControl } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getStoredSession, isEntConnected } from "@/lib/ent/auth";
import { listMessages, type EntMessage } from "@/lib/ent/zimbra";
import { getEntProvider, type EntProvider } from "@/lib/ent/providers";

export default function MessagesScreen() {
  const theme = useTheme();
  const [connected, setConnected] = useState<boolean | null>(null);
  const [provider, setProvider] = useState<EntProvider | null>(null);
  const [messages, setMessages] = useState<EntMessage[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const checkConnection = useCallback(async () => {
    const session = await getStoredSession();
    const ok = isEntConnected(session);
    setConnected(ok);
    if (ok && session) {
      const prov = getEntProvider(session.providerId);
      setProvider(prov ?? null);
      if (prov) loadMessages(prov);
    }
  }, []);

  useEffect(() => {
    checkConnection();
  }, [checkConnection]);

  async function loadMessages(prov?: EntProvider) {
    const p = prov ?? provider;
    if (!p) return;
    setLoading(true);
    setError(null);
    try {
      const msgs = await listMessages(p, "INBOX", 0);
      setMessages(msgs);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "Erreur inconnue";
      setError(msg);
      console.warn("[nōto] Messages load error:", e);
    } finally {
      setLoading(false);
    }
  }

  // Not connected to ENT
  if (connected === false) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyTitle, { color: theme.text }]}>
          Messagerie
        </Text>
        <Text style={[styles.emptyText, { color: theme.textSecondary }]}>
          Connectez votre compte Mon Lycée pour accéder à la messagerie.
        </Text>
        <Pressable
          style={[styles.connectBtn, { backgroundColor: "#1B3A6B" }]}
          onPress={() => router.push("/auth/ent")}
        >
          <Text style={styles.connectBtnText}>Connecter Mon Lycée</Text>
        </Pressable>
      </View>
    );
  }

  // Loading initial state
  if (connected === null) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <ActivityIndicator color={theme.accent} />
      </View>
    );
  }

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
      refreshControl={
        <RefreshControl refreshing={loading} onRefresh={() => loadMessages()} tintColor={theme.accent} />
      }
    >
      {error && (
        <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>
      )}

      {messages.length === 0 && !loading && (
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Aucun message.
        </Text>
      )}

      {messages.map((msg) => {
        const date = new Date(msg.date);
        const dateStr = date.toLocaleDateString("fr-FR", {
          day: "numeric",
          month: "short",
        });

        return (
          <Pressable
            key={msg.id}
            style={[
              styles.messageRow,
              {
                backgroundColor: theme.surface,
                borderColor: theme.border,
                opacity: msg.isRead ? 0.7 : 1,
              },
            ]}
          >
            {/* Unread indicator */}
            {!msg.isRead && (
              <View style={[styles.unreadDot, { backgroundColor: theme.accent }]} />
            )}
            <View style={styles.messageContent}>
              <View style={styles.messageHeader}>
                <Text
                  style={[
                    styles.messageFrom,
                    {
                      color: theme.text,
                      fontFamily: msg.isRead ? Fonts.regular : Fonts.semiBold,
                    },
                  ]}
                  numberOfLines={1}
                >
                  {msg.from}
                </Text>
                <Text style={[styles.messageDate, { color: theme.textTertiary }]}>
                  {dateStr}
                </Text>
              </View>
              <Text
                style={[
                  styles.messageSubject,
                  {
                    color: msg.isRead ? theme.textSecondary : theme.text,
                    fontFamily: msg.isRead ? Fonts.regular : Fonts.medium,
                  },
                ]}
                numberOfLines={1}
              >
                {msg.subject}
              </Text>
              {msg.hasAttachment && (
                <Text style={[styles.attachment, { color: theme.textTertiary }]}>
                  📎 Pièce jointe
                </Text>
              )}
            </View>
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  empty: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    padding: Spacing.xl,
    gap: Spacing.md,
  },
  emptyTitle: {
    fontSize: FontSize.xl,
    fontFamily: Fonts.bold,
  },
  emptyText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    textAlign: "center",
    lineHeight: 22,
  },
  connectBtn: {
    borderRadius: BorderRadius.md,
    paddingVertical: 14,
    paddingHorizontal: Spacing.xl,
    marginTop: Spacing.sm,
  },
  connectBtnText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.semiBold,
    color: "#FFFFFF",
  },
  error: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    marginBottom: Spacing.md,
  },
  messageRow: {
    flexDirection: "row",
    alignItems: "flex-start",
    padding: 14,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: 4,
    gap: Spacing.sm,
  },
  unreadDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginTop: 6,
  },
  messageContent: { flex: 1, gap: 3 },
  messageHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  messageFrom: {
    fontSize: FontSize.md,
    flex: 1,
  },
  messageDate: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.mono,
    marginLeft: Spacing.sm,
  },
  messageSubject: {
    fontSize: FontSize.sm,
  },
  attachment: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
    marginTop: 2,
  },
});
