import { useEffect, useState, useCallback } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator, RefreshControl } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getStoredSession } from "@/lib/ent/auth";
import { getMailCredentials, fetchInbox, type MailMessage } from "@/lib/ent/mail";
import { getConversationCredentials, fetchConversationInbox, type ConversationMessage } from "@/lib/ent/conversation";
import { getEntProvider } from "@/lib/ent/providers";

interface DisplayMessage {
  id: string;
  subject: string;
  from: string;
  date: string;
  unread: boolean;
  hasAttachment: boolean;
}

export default function MessagesScreen() {
  const theme = useTheme();
  const [connected, setConnected] = useState<boolean | null>(null);
  const [messages, setMessages] = useState<DisplayMessage[]>([]);
  const [unseen, setUnseen] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadMessages = useCallback(async () => {
    // Check which messaging system is configured
    // Use the most recently connected ENT session to determine which to use
    const session = await getStoredSession();
    const imapCreds = await getMailCredentials();
    const convCreds = await getConversationCredentials();

    if (!imapCreds && !convCreds) {
      setConnected(false);
      return;
    }

    // Determine which backend based on the active ENT provider
    const provider = session ? getEntProvider(session.providerId) : null;
    const useConversation = convCreds && provider?.messagingType === "conversation";
    const useIMAP = imapCreds && (!useConversation);

    setConnected(true);
    setLoading(true);
    setError(null);

    try {
      if (useConversation && convCreds) {
        // PCN: ENTCore Conversation API
        const result = await fetchConversationInbox(convCreds, 0);
        setMessages(result.messages.map((m) => ({
          id: m.id,
          subject: m.subject,
          from: m.from,
          date: m.date ? new Date(m.date).toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) : "",
          unread: m.unread,
          hasAttachment: m.hasAttachment,
        })));
        setUnseen(result.count);
      } else if (useIMAP && imapCreds) {
        // Mon Lycée: IMAP via proxy
        const result = await fetchInbox(imapCreds, 0);
        setMessages(result.messages.map((m) => ({
          id: String(m.id),
          subject: m.subject,
          from: m.from,
          date: m.date ? new Date(m.date).toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) : "",
          unread: m.unread,
          hasAttachment: m.hasAttachment,
        })));
        setUnseen(result.unseen);
      }
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "Erreur";
      setError(msg);
      console.warn("[nōto] Messages error:", e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadMessages();
  }, [loadMessages]);

  if (connected === false) {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyTitle, { color: theme.text }]}>Messagerie</Text>
        <Text style={[styles.emptyText, { color: theme.textSecondary }]}>
          Connectez votre messagerie ENT pour voir vos messages.
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
      refreshControl={<RefreshControl refreshing={loading} onRefresh={loadMessages} tintColor={theme.accent} />}
    >
      {unseen > 0 && (
        <View style={[styles.badge, { backgroundColor: theme.accent }]}>
          <Text style={styles.badgeText}>{unseen} non lu{unseen > 1 ? "s" : ""}</Text>
        </View>
      )}

      {error && <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>}

      {messages.length === 0 && !loading && (
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>Aucun message.</Text>
      )}

      {messages.map((msg) => (
        <View
          key={msg.id}
          style={[
            styles.messageRow,
            { backgroundColor: theme.surface, borderColor: theme.border, opacity: msg.unread ? 1 : 0.7 },
          ]}
        >
          {msg.unread && <View style={[styles.unreadDot, { backgroundColor: theme.accent }]} />}
          <View style={styles.messageContent}>
            <View style={styles.messageHeader}>
              <Text
                style={[styles.messageFrom, { color: theme.text, fontFamily: msg.unread ? Fonts.semiBold : Fonts.regular }]}
                numberOfLines={1}
              >
                {msg.from}
              </Text>
              <Text style={[styles.messageDate, { color: theme.textTertiary }]}>{msg.date}</Text>
            </View>
            <Text
              style={[styles.messageSubject, { color: msg.unread ? theme.text : theme.textSecondary, fontFamily: msg.unread ? Fonts.medium : Fonts.regular }]}
              numberOfLines={1}
            >
              {msg.subject}
            </Text>
            {msg.hasAttachment && (
              <Text style={[styles.attachment, { color: theme.textTertiary }]}>📎 Pièce jointe</Text>
            )}
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  empty: { flex: 1, justifyContent: "center", alignItems: "center", padding: Spacing.xl, gap: Spacing.md },
  emptyTitle: { fontSize: FontSize.xl, fontFamily: Fonts.bold },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center", lineHeight: 22 },
  connectBtn: { borderRadius: BorderRadius.md, paddingVertical: 14, paddingHorizontal: Spacing.xl, marginTop: Spacing.sm },
  connectBtnText: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  badge: { alignSelf: "flex-start", paddingHorizontal: 12, paddingVertical: 4, borderRadius: 12, marginBottom: Spacing.md },
  badgeText: { fontSize: FontSize.sm, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  error: { fontSize: FontSize.sm, fontFamily: Fonts.regular, marginBottom: Spacing.md },
  messageRow: { flexDirection: "row", alignItems: "flex-start", padding: 14, borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: 4, gap: Spacing.sm },
  unreadDot: { width: 8, height: 8, borderRadius: 4, marginTop: 6 },
  messageContent: { flex: 1, gap: 3 },
  messageHeader: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  messageFrom: { fontSize: FontSize.md, flex: 1 },
  messageDate: { fontSize: FontSize.xs, fontFamily: Fonts.mono, marginLeft: Spacing.sm },
  messageSubject: { fontSize: FontSize.sm },
  attachment: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: 2 },
});
