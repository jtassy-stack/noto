import { View, Text, StyleSheet, Pressable, Alert } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { ENT_PROVIDERS } from "@/lib/ent/providers";

export default function AuthScreen() {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <Text style={[styles.title, { color: theme.text }]}>
        Connecter un service
      </Text>

      {/* Pronote */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>
        NOTES · EMPLOI DU TEMPS · DEVOIRS
      </Text>
      <Pressable
        style={({ pressed }) => [
          styles.card,
          { backgroundColor: theme.surface, borderColor: pressed ? theme.accent : theme.border },
        ]}
        onPress={() => {
          Alert.alert("Pronote", "Comment souhaitez-vous vous connecter ?", [
            { text: "QR code (recommandé)", onPress: () => router.push("/auth/qrcode") },
            { text: "Identifiants", onPress: () => router.push("/auth/pronote") },
            { text: "Annuler", style: "cancel" },
          ]);
        }}
      >
        <View style={[styles.iconBox, { backgroundColor: theme.surfaceElevated }]}>
          <Text style={[styles.iconText, { color: theme.accent }]}>P</Text>
        </View>
        <View style={styles.textBlock}>
          <Text style={[styles.cardTitle, { color: theme.text }]}>Pronote</Text>
          <Text style={[styles.cardDesc, { color: theme.textSecondary }]}>
            QR code ou identifiants directs
          </Text>
        </View>
      </Pressable>

      {/* Messagerie ENT */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.xl }]}>
        MESSAGERIE
      </Text>
      {ENT_PROVIDERS.map((ent) => (
        <Pressable
          key={ent.id}
          style={({ pressed }) => [
            styles.card,
            { backgroundColor: theme.surface, borderColor: pressed ? ent.color : theme.border },
          ]}
          onPress={() => router.push(`/auth/ent?provider=${ent.id}`)}
        >
          <View style={[styles.iconBox, { backgroundColor: ent.color }]}>
            <Text style={styles.iconEmoji}>{ent.icon}</Text>
          </View>
          <View style={styles.textBlock}>
            <Text style={[styles.cardTitle, { color: theme.text }]}>{ent.name}</Text>
            <Text style={[styles.cardDesc, { color: theme.textSecondary }]}>{ent.description}</Text>
          </View>
        </Pressable>
      ))}

      <Text style={[styles.privacy, { color: theme.textTertiary }]}>
        🔒 Vos identifiants sont stockés uniquement sur votre téléphone.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: Spacing.lg, paddingTop: Spacing.xl },
  title: { fontSize: FontSize.xxl, fontFamily: Fonts.bold, marginBottom: Spacing.lg },
  sectionLabel: { fontSize: 11, fontFamily: Fonts.medium, letterSpacing: 1.5, marginBottom: Spacing.sm },
  card: {
    flexDirection: "row", alignItems: "center",
    borderRadius: BorderRadius.lg, padding: 16, borderWidth: 1,
    gap: Spacing.md, marginBottom: Spacing.sm,
  },
  iconBox: { width: 40, height: 40, borderRadius: BorderRadius.lg, justifyContent: "center", alignItems: "center" },
  iconText: { fontSize: 18, fontFamily: Fonts.monoBold },
  iconEmoji: { fontSize: 20 },
  textBlock: { flex: 1, gap: 2 },
  cardTitle: { fontSize: FontSize.lg - 1, fontFamily: Fonts.semiBold },
  cardDesc: { fontSize: FontSize.sm, fontFamily: Fonts.regular },
  privacy: { fontSize: FontSize.xs, fontFamily: Fonts.regular, marginTop: Spacing.xxl, textAlign: "center", lineHeight: 16 },
});
