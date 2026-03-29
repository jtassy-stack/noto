import { useState } from "react";
import {
  View, Text, TextInput, Pressable, StyleSheet,
  ActivityIndicator, ScrollView, Alert,
} from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { getConversationCredentials } from "@/lib/ent/conversation";
import type { ConversationCredentials } from "@/lib/ent/conversation";
import {
  MOTIF_LABELS,
  type AbsenceMotif,
  type AbsenceRequest,
} from "@/lib/ent/absence";
import type { Child } from "@/types";

const MOTIFS: AbsenceMotif[] = ["maladie", "rdv_medical", "raison_familiale", "autre"];

function formatDate(d: Date): string {
  return d.toLocaleDateString("fr-FR", {
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  });
}

export default function AbsenceScreen() {
  const theme = useTheme();
  const { childId, childFirstName, childLastName, childClassName } = useLocalSearchParams<{
    childId: string;
    childFirstName: string;
    childLastName: string;
    childClassName: string;
  }>();

  const activeChild: Child | null = childId ? {
    id: childId,
    accountId: "",
    firstName: childFirstName ?? "",
    lastName: childLastName ?? "",
    className: childClassName ?? "",
    source: "ent",
  } : null;

  const [motif, setMotif] = useState<AbsenceMotif>("maladie");
  const [motifDetail, setMotifDetail] = useState("");
  const [dayOffset, setDayOffset] = useState(0); // 0=today, 1=tomorrow, etc.
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState(false);
  const [recipients, setRecipients] = useState<string[] | null>(null);
  const [cachedCreds, setCachedCreds] = useState<ConversationCredentials | null>(null);
  const [sent, setSent] = useState(false);

  const selectedDate = new Date();
  selectedDate.setDate(selectedDate.getDate() + dayOffset);

  async function handlePreview() {
    if (!activeChild) return;

    const creds = await getConversationCredentials();
    if (!creds) {
      Alert.alert("Erreur", "Connectez d'abord votre compte PCN.");
      return;
    }

    setLoading(true);

    try {
      const { findRecipientsOnly } = await import("@/lib/ent/absence");
      const found = await findRecipientsOnly(creds, activeChild);
      setRecipients(found);
      setCachedCreds(creds);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "Erreur inconnue";
      Alert.alert("Erreur", msg);
      console.warn("[nōto] Absence preview error:", e);
    } finally {
      setLoading(false);
    }
  }

  function handleSendConfirm() {
    Alert.alert(
      "Confirmer l'envoi",
      "Êtes-vous sûr de vouloir envoyer ce message d'absence ?",
      [
        { text: "Annuler", style: "cancel" },
        { text: "Envoyer", style: "destructive", onPress: handleSend },
      ]
    );
  }

  async function handleSend() {
    if (!activeChild || !cachedCreds) return;

    setSending(true);

    try {
      const parentName = activeChild.lastName
        ? `M./Mme ${activeChild.lastName}`
        : "Le parent";

      const req: AbsenceRequest = {
        child: activeChild,
        date: formatDate(selectedDate),
        motif,
        motifDetail: motif === "autre" ? motifDetail : undefined,
        parentName,
      };

      const { sendAbsenceNotification } = await import("@/lib/ent/absence");
      await sendAbsenceNotification(cachedCreds, req);
      setSent(true);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "Erreur inconnue";
      Alert.alert("Erreur", msg);
      console.warn("[nōto] Absence send error:", e);
    } finally {
      setSending(false);
    }
  }

  if (!activeChild || activeChild.source !== "ent") {
    return (
      <View style={[styles.empty, { backgroundColor: theme.background }]}>
        <Text style={[styles.emptyText, { color: theme.textTertiary }]}>
          Sélectionnez un enfant ENT pour signaler une absence.
        </Text>
      </View>
    );
  }

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.background }]}
      contentContainerStyle={styles.content}
    >
      {/* Child info */}
      <View style={[styles.childCard, { backgroundColor: theme.surface, borderColor: theme.border }]}>
        <Text style={[styles.childName, { color: theme.text }]}>
          {activeChild.firstName} {activeChild.lastName}
        </Text>
        <Text style={[styles.childClass, { color: theme.textSecondary }]}>
          {activeChild.className}
        </Text>
      </View>

      {/* Date selector */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>DATE</Text>
      <View style={styles.dateRow}>
        {[0, 1, 2].map((offset) => {
          const d = new Date();
          d.setDate(d.getDate() + offset);
          const label = offset === 0 ? "Aujourd'hui" : offset === 1 ? "Demain" : d.toLocaleDateString("fr-FR", { weekday: "short", day: "numeric" });
          const active = dayOffset === offset;
          return (
            <Pressable
              key={offset}
              onPress={() => setDayOffset(offset)}
              style={[
                styles.dateBtn,
                {
                  backgroundColor: active ? theme.accent : theme.surfaceElevated,
                  borderColor: active ? theme.accent : theme.border,
                },
              ]}
            >
              <Text style={[styles.dateBtnText, { color: active ? "#FFFFFF" : theme.text }]}>
                {label}
              </Text>
            </Pressable>
          );
        })}
      </View>

      {/* Motif selector */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>MOTIF</Text>
      <View style={styles.motifList}>
        {MOTIFS.map((m) => {
          const active = motif === m;
          return (
            <Pressable
              key={m}
              onPress={() => setMotif(m)}
              style={[
                styles.motifBtn,
                {
                  backgroundColor: active ? theme.accent : theme.surface,
                  borderColor: active ? theme.accent : theme.border,
                },
              ]}
            >
              <Text style={[styles.motifText, { color: active ? "#FFFFFF" : theme.text }]}>
                {MOTIF_LABELS[m]}
              </Text>
            </Pressable>
          );
        })}
      </View>

      {motif === "autre" && (
        <TextInput
          style={[styles.input, { backgroundColor: theme.surface, color: theme.text, borderColor: theme.border }]}
          placeholder="Précisez le motif..."
          placeholderTextColor={theme.textTertiary}
          value={motifDetail}
          onChangeText={setMotifDetail}
          multiline
          numberOfLines={2}
        />
      )}

      {/* Preview */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.lg }]}>APERÇU</Text>
      <View style={[styles.preview, { backgroundColor: theme.surface, borderColor: theme.border }]}>
        <Text style={[styles.previewSubject, { color: theme.text }]}>
          Absence de {activeChild.firstName} - {activeChild.className} - {formatDate(selectedDate)}
        </Text>
        <Text style={[styles.previewBody, { color: theme.textSecondary }]}>
          Madame, Monsieur,{"\n\n"}
          Je vous informe que mon enfant {activeChild.firstName} {activeChild.lastName}, en classe de {activeChild.className}, sera absent(e) le {formatDate(selectedDate)}.{"\n\n"}
          Motif : {motif === "autre" ? (motifDetail || "...") : MOTIF_LABELS[motif]}
        </Text>
        <Text style={[styles.previewTo, { color: theme.textTertiary }]}>
          → Enseignant(e) + Direction
        </Text>
      </View>

      {/* Recipients preview */}
      {recipients && recipients.length > 0 && (
        <View style={[styles.recipientsCard, { backgroundColor: theme.surface, borderColor: theme.border }]}>
          <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: 0 }]}>
            DESTINATAIRES ({recipients.length})
          </Text>
          {recipients.map((r, i) => (
            <Text key={i} style={[styles.recipientName, { color: theme.text }]}>
              {r}
            </Text>
          ))}
        </View>
      )}

      {/* Preview button — step 1 */}
      {!recipients && (
        <Pressable
          style={({ pressed }) => [
            styles.sendBtn,
            { backgroundColor: theme.accent, opacity: pressed || loading ? 0.7 : 1 },
          ]}
          onPress={handlePreview}
          disabled={loading}
        >
          {loading ? (
            <ActivityIndicator color="#FFFFFF" size="small" />
          ) : (
            <Text style={styles.sendBtnText}>Aperçu des destinataires</Text>
          )}
        </Pressable>
      )}

      {/* Send button — step 2 (only after preview) */}
      {recipients && !sent && (
        <Pressable
          style={({ pressed }) => [
            styles.sendBtn,
            { backgroundColor: theme.crimson, opacity: pressed || sending ? 0.7 : 1 },
          ]}
          onPress={handleSendConfirm}
          disabled={sending}
        >
          {sending ? (
            <ActivityIndicator color="#FFFFFF" size="small" />
          ) : (
            <Text style={styles.sendBtnText}>Confirmer l'envoi</Text>
          )}
        </Pressable>
      )}

      {/* Sent confirmation */}
      {sent && (
        <View style={styles.sentContainer}>
          <Text style={styles.sentCheck}>✓</Text>
          <Text style={[styles.sentText, { color: theme.accent }]}>Message envoyé</Text>
          <Pressable
            style={({ pressed }) => [
              styles.backBtn,
              { backgroundColor: theme.surface, borderColor: theme.border, opacity: pressed ? 0.7 : 1 },
            ]}
            onPress={() => router.back()}
          >
            <Text style={[styles.backBtnText, { color: theme.text }]}>Retour</Text>
          </Pressable>
        </View>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: Spacing.lg, paddingTop: Spacing.md, paddingBottom: Spacing.xxl },
  empty: { flex: 1, justifyContent: "center", alignItems: "center", padding: Spacing.xl },
  emptyText: { fontSize: FontSize.md, fontFamily: Fonts.regular, textAlign: "center" },

  childCard: { padding: Spacing.md, borderRadius: BorderRadius.md, borderWidth: 1, marginBottom: Spacing.lg },
  childName: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold },
  childClass: { fontSize: FontSize.sm, fontFamily: Fonts.regular, marginTop: 2 },

  sectionLabel: { fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5, marginBottom: Spacing.sm },

  dateRow: { flexDirection: "row", gap: Spacing.sm, marginBottom: Spacing.lg },
  dateBtn: { flex: 1, paddingVertical: 12, borderRadius: BorderRadius.md, borderWidth: 1, alignItems: "center" },
  dateBtnText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },

  motifList: { flexDirection: "row", flexWrap: "wrap", gap: Spacing.sm, marginBottom: Spacing.md },
  motifBtn: { paddingVertical: 10, paddingHorizontal: 16, borderRadius: BorderRadius.md, borderWidth: 1 },
  motifText: { fontSize: FontSize.sm, fontFamily: Fonts.medium },

  input: { borderWidth: 1, borderRadius: BorderRadius.md, padding: Spacing.md, fontSize: FontSize.md, fontFamily: Fonts.regular, minHeight: 60, textAlignVertical: "top" },

  preview: { padding: Spacing.md, borderRadius: BorderRadius.md, borderWidth: 1, gap: Spacing.sm },
  previewSubject: { fontSize: FontSize.md, fontFamily: Fonts.semiBold },
  previewBody: { fontSize: FontSize.sm, fontFamily: Fonts.regular, lineHeight: 20 },
  previewTo: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.xs },

  recipientsCard: { padding: Spacing.md, borderRadius: BorderRadius.md, borderWidth: 1, marginTop: Spacing.lg, gap: Spacing.xs },
  recipientName: { fontSize: FontSize.sm, fontFamily: Fonts.regular, paddingVertical: 2 },

  sendBtn: { borderRadius: BorderRadius.md, paddingVertical: 16, alignItems: "center", marginTop: Spacing.xl },
  sendBtnText: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, color: "#FFFFFF" },

  sentContainer: { alignItems: "center", marginTop: Spacing.xl, gap: Spacing.md },
  sentCheck: { fontSize: 48, color: "#34C759" },
  sentText: { fontSize: FontSize.xl, fontFamily: Fonts.semiBold },
  backBtn: { borderRadius: BorderRadius.md, paddingVertical: 12, paddingHorizontal: 32, borderWidth: 1, marginTop: Spacing.sm },
  backBtnText: { fontSize: FontSize.md, fontFamily: Fonts.medium },
});
