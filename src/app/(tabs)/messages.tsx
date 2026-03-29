import { useEffect, useState, useCallback } from "react";
import { View, Text, StyleSheet, ScrollView, Pressable, ActivityIndicator, RefreshControl } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getMailCredentials, fetchInbox, type MailMessage } from "@/lib/ent/mail";
import { getConversationCredentials, fetchConversationInbox, filterMessagesByChild, type ConversationMessage } from "@/lib/ent/conversation";

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
  const { activeChild } = useChildren();
  const [connected, setConnected] = useState<boolean | null>(null);
  const [messages, setMessages] = useState<DisplayMessage[]>([]);
  const [unseen, setUnseen] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadMessages = useCallback(async () => {
    const imapCreds = await getMailCredentials();
    const convCreds = await getConversationCredentials();

    if (!imapCreds && !convCreds) {
      setConnected(false);
      return;
    }

    // Pick messaging backend based on selected child's source
    // ENT child → Conversation API (PCN)
    // Pronote child → IMAP (Mon Lycée) if available
    // No child selected → use whatever is available
    const isEntChild = activeChild?.source === "ent";
    const useConversation = convCreds && (isEntChild || !imapCreds);
    const useIMAP = imapCreds && !isEntChild;

    setConnected(true);
    setLoading(true);
    setError(null);

    try {
      if (useConversation && convCreds) {
        // PCN: ENTCore Conversation API — filtered by child's class
        const result = await fetchConversationInbox(convCreds, 0);
        const filtered = activeChild?.className
          ? filterMessagesByChild(result.messages, activeChild.className)
          : result.messages;
        console.log("[nōto] Messages:", result.messages.length, "total →", filtered.length, "for", activeChild?.firstName);
        setMessages(filtered.map((m) => ({
          id: m.id,
          subject: m.subject,
          from: m.from,
          date: m.date ? new Date(m.date).toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) : "",
          unread: m.unread,
          hasAttachment: m.hasAttachment,
        })));
        setUnseen(filtered.filter(m => m.unread).length);
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
  }, [activeChild]);

  useEffect(() => {
    loadMessages();
  }, [loadMessages, activeChild]);

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
      {/* Absence button for ENT children */}
      {activeChild?.source === "ent" && (
        <Pressable
          onPress={() => router.push({
            pathname: "/absence",
            params: {
              childId: activeChild.id,
              childFirstName: activeChild.firstName,
              childLastName: activeChild.lastName,
              childClassName: activeChild.className,
            },
          })}
          style={[styles.absenceBtn, { backgroundColor: theme.crimson }]}
        >
          <Text style={styles.absenceBtnText}>Signaler une absence</Text>
        </Pressable>
      )}

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
        <Pressable
          key={msg.id}
          onPress={() => {
            const isEntChild = activeChild?.source === "ent";
            router.push({
              pathname: "/message",
              params: { id: msg.id, from: msg.from, subject: msg.subject, date: msg.date, source: isEntChild ? "ent" : "imap" },
            });
          }}
          style={[
            styles.messageRow,
            { borderBottomColor: theme.border, opacity: msg.unread ? 1 : 0.7 },
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
              <Text style={[styles.attachment, { color: theme.textTertiary }]}>Pièce jointe</Text>
            )}
          </View>
        </Pressable>
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
  absenceBtn: { borderRadius: 10, paddingVertical: 12, alignItems: "center", marginBottom: Spacing.md },
  absenceBtnText: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
  badge: { alignSelf: "flex-start", paddingHorizontal: 8, paddingVertical: 4, borderRadius: 4, marginBottom: Spacing.md },
  badgeText: { fontSize: FontSize.xs, fontFamily: Fonts.bold, color: "#FFFFFF" },
  error: { fontSize: FontSize.sm, fontFamily: Fonts.regular, marginBottom: Spacing.md },
  messageRow: { flexDirection: "row", alignItems: "flex-start", paddingVertical: 12, gap: Spacing.sm, borderBottomWidth: StyleSheet.hairlineWidth },
  unreadDot: { width: 6, height: 6, borderRadius: 3, marginTop: 7 },
  messageContent: { flex: 1, gap: 3 },
  messageHeader: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  messageFrom: { fontSize: FontSize.md, flex: 1 },
  messageDate: { fontSize: FontSize.xs, fontFamily: Fonts.mono, marginLeft: Spacing.sm },
  messageSubject: { fontSize: 13 },
  attachment: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: 2 },
});
