import { useState } from "react";
import {
  View, Text, TextInput, Pressable, StyleSheet,
  ActivityIndicator, ScrollView, Alert,
} from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";
import { getConversationCredentials } from "@/lib/ent/conversation";
import {
  sendAbsenceNotification,
  MOTIF_LABELS,
  type AbsenceMotif,
  type AbsenceRequest,
} from "@/lib/ent/absence";

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
  const { activeChild } = useChildren();

  const [motif, setMotif] = useState<AbsenceMotif>("maladie");
  const [motifDetail, setMotifDetail] = useState("");
  const [dayOffset, setDayOffset] = useState(0); // 0=today, 1=tomorrow, etc.
  const [sending, setSending] = useState(false);

  const selectedDate = new Date();
  selectedDate.setDate(selectedDate.getDate() + dayOffset);

  async function handleSend() {
    if (!activeChild) return;

    const creds = await getConversationCredentials();
    if (!creds) {
      Alert.alert("Erreur", "Connectez d'abord votre compte PCN.");
      return;
    }

    setSending(true);

    try {
      const req: AbsenceRequest = {
        child: activeChild,
        date: formatDate(selectedDate),
        motif,
        motifDetail: motif === "autre" ? motifDetail : undefined,
        parentName: "M./Mme TASSY", // TODO: get from userinfo
      };

      await sendAbsenceNotification(creds, req);

      Alert.alert(
        "Absence signalée ✅",
        `Le message a été envoyé pour ${activeChild.firstName}.`,
        [{ text: "OK", onPress: () => router.back() }]
      );
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

      {/* Send button */}
      <Pressable
        style={({ pressed }) => [
          styles.sendBtn,
          { backgroundColor: theme.crimson, opacity: pressed || sending ? 0.7 : 1 },
        ]}
        onPress={handleSend}
        disabled={sending}
      >
        {sending ? (
          <ActivityIndicator color="#FFFFFF" size="small" />
        ) : (
          <Text style={styles.sendBtnText}>Envoyer le signalement</Text>
        )}
      </Pressable>
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

  sendBtn: { borderRadius: BorderRadius.md, paddingVertical: 16, alignItems: "center", marginTop: Spacing.xl },
  sendBtnText: { fontSize: FontSize.lg, fontFamily: Fonts.semiBold, color: "#FFFFFF" },
});
