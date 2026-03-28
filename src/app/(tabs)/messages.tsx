import { useEffect, useState, useCallback } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getStoredSession, isEntConnected, type EntSession } from "@/lib/ent/auth";

interface EntMessage {
  id: string;
  subject: string;
  from: string;
  date: string;
  unread: boolean;
  hasAttachment: boolean;
}

function parseMessages(raw: string | undefined): EntMessage[] {
  if (!raw) return [];
  try {
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return [];
    return arr.map((msg: Record<string, unknown>) => ({
      id: String(msg.id ?? ""),
      subject: String(msg.subject ?? "(sans objet)"),
      from: String(msg.from ?? (Array.isArray(msg.displayNames) ? (msg.displayNames as string[][])?.[0]?.[1] : undefined) ?? "Inconnu"),
      date: new Date(Number(msg.date) || Date.now()).toISOString(),
      unread: Boolean(msg.unread),
      hasAttachment: Boolean(msg.hasAttachment),
    }));
  } catch {
    return [];
  }
}

export default function MessagesScreen() {
  const theme = useTheme();
  const [connected, setConnected] = useState<boolean | null>(null);
  const [messages, setMessages] = useState<EntMessage[]>([]);
  const [loading, setLoading] = useState(false);

  const checkConnection = useCallback(async () => {
    const session = await getStoredSession();
    const ok = isEntConnected(session);
    setConnected(ok);
    if (ok && session?.cachedMessages) {
      const msgs = parseMessages(session.cachedMessages);
      setMessages(msgs);
      console.log("[nōto] Loaded", msgs.length, "cached messages");
    }
  }, []);

  useEffect(() => {
    checkConnection();
  }, [checkConnection]);

  // Not connected
  if (connected === false) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyTitle, { color: theme.text }]}>
          Messagerie
        </Text>
        <Text style={[styles.emptyText, { color: theme.textSecondary }]}>
          Connectez votre compte ENT pour accéder à la messagerie.
        </Text>
        <Pressable
          style={[styles.connectBtn, { backgroundColor: "#1B3A6B" }]}
          onPress={() => router.push("/auth/")}
        >
          <Text style={styles.connectBtnText}>Connecter un compte</Text>
        </Pressable>
      </View>
    );
  }

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
    >
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
          <View
            key={msg.id}
            style={[
              styles.messageRow,
              {
                backgroundColor: theme.surface,
                borderColor: theme.border,
                opacity: msg.unread ? 1 : 0.7,
              },
            ]}
          >
            {msg.unread && (
              <View style={[styles.unreadDot, { backgroundColor: theme.accent }]} />
            )}
            <View style={styles.messageContent}>
              <View style={styles.messageHeader}>
                <Text
                  style={[
                    styles.messageFrom,
                    {
                      color: theme.text,
                      fontFamily: msg.unread ? Fonts.semiBold : Fonts.regular,
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
                    color: msg.unread ? theme.text : theme.textSecondary,
                    fontFamily: msg.unread ? Fonts.medium : Fonts.regular,
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
          </View>
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
  emptyTitle: { fontSize: FontSize.xl, fontFamily: Fonts.bold },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", lineHeight: 22 },
  connectBtn: {
    borderRadius: BorderRadius.md,
    paddingVertical: 14,
    paddingHorizontal: Spacing.xl,
    marginTop: Spacing.sm,
  },
  connectBtnText: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  messageRow: {
    flexDirection: "row",
    alignItems: "flex-start",
    padding: 14,
    borderRadius: BorderRadius.md,
    borderWidth: 1,
    marginBottom: 4,
    gap: Spacing.sm,
  },
  unreadDot: { width: 8, height: 8, borderRadius: 4, marginTop: 6 },
  messageContent: { flex: 1, gap: 3 },
  messageHeader: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  messageFrom: { fontSize: FontSize.md, flex: 1 },
  messageDate: { fontSize: FontSize.xs, fontFamily: Fonts.mono, marginLeft: Spacing.sm },
  messageSubject: { fontSize: FontSize.sm },
  attachment: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: 2 },
});
