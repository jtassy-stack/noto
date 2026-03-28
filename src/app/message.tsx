import { useEffect, useState } from "react";
import { View, Text, ScrollView, StyleSheet, ActivityIndicator } from "react-native";
import { useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getMailCredentials, fetchMessage as fetchImapMessage } from "@/lib/ent/mail";
import { getConversationCredentials, fetchConversationMessage } from "@/lib/ent/conversation";

export default function MessageScreen() {
  const theme = useTheme();
  const { activeChild } = useChildren();
  const { id, from, subject, date } = useLocalSearchParams<{
    id: string;
    from: string;
    subject: string;
    date: string;
  }>();

  const [body, setBody] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function load() {
      if (!id) return;

      try {
        const isEnt = activeChild?.source === "ent";
        console.log("[nōto] Opening message:", id, "isEnt:", isEnt, "child:", activeChild?.firstName);

        if (isEnt) {
          const creds = await getConversationCredentials();
          console.log("[nōto] PCN creds:", creds ? "yes" : "no");
          if (creds) {
            const msg = await fetchConversationMessage(creds, id);
            console.log("[nōto] Message loaded, body length:", msg.body?.length);
            setBody(stripHtml(msg.body ?? ""));
          } else {
            setError("Reconnectez votre compte PCN.");
          }
        } else {
          const creds = await getMailCredentials();
          console.log("[nōto] IMAP creds:", creds ? "yes" : "no");
          if (creds) {
            const msg = await fetchImapMessage(creds, parseInt(id, 10));
            setBody(msg.body ?? "");
          } else {
            setError("Reconnectez votre compte messagerie.");
          }
        }
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : "Erreur";
        setError(msg);
        console.warn("[nōto] Message fetch error:", e);
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, activeChild]);

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {/* Header */}
      <Text style={[styles.subject, { color: theme.text }]}>
        {subject || "(sans objet)"}
      </Text>

      <View style={styles.metaRow}>
        <Text style={[styles.from, { color: theme.accent }]}>{from}</Text>
        <Text style={[styles.date, { color: theme.textTertiary }]}>{date}</Text>
      </View>

      <View style={[styles.divider, { backgroundColor: theme.border }]} />

      {/* Body */}
      {loading && <ActivityIndicator color={theme.accent} style={{ marginTop: Spacing.xl }} />}

      {error && (
        <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>
      )}

      {body !== null && (
        <Text style={[styles.body, { color: theme.text }]}>{body}</Text>
      )}
    </ScrollView>
  );
}

function stripHtml(html: string): string {
  return html
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  subject: { fontSize: FontSize.xl, fontFamily: Fonts.bold, lineHeight: 28 },
  metaRow: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", marginTop: Spacing.sm },
  from: { fontSize: FontSize.md, fontFamily: Fonts.semiBold, flex: 1 },
  date: { fontSize: FontSize.sm, fontFamily: Fonts.mono },
  divider: { height: 1, marginVertical: Spacing.md },
  error: { fontSize: FontSize.md, fontFamily: Fonts.regular, marginTop: Spacing.md },
  body: { fontSize: FontSize.md, fontFamily: Fonts.regular, lineHeight: 24 },
});
