import { View, Text, StyleSheet, Pressable, Alert } from "react-native";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { ENT_PROVIDERS } from "@/lib/ent/providers";
import type { Provider } from "@/types";

export default function AuthScreen() {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <Text style={[styles.title, { color: theme.text }]}>
        Connecter un compte
      </Text>

      {/* ENT section */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary }]}>
        VIA VOTRE ENT
      </Text>
      <View style={styles.providers}>
        {ENT_PROVIDERS.map((ent) => (
          <Pressable
            key={ent.id}
            style={({ pressed }) => [
              styles.providerCard,
              {
                backgroundColor: theme.surface,
                borderColor: pressed ? ent.color : theme.border,
              },
            ]}
            onPress={() => router.push(`/auth/ent?provider=${ent.id}`)}
          >
            <View style={[styles.iconBox, { backgroundColor: ent.color }]}>
              <Text style={styles.iconEmoji}>{ent.icon}</Text>
            </View>
            <View style={styles.textBlock}>
              <Text style={[styles.providerLabel, { color: theme.text }]}>
                {ent.name}
              </Text>
              <Text style={[styles.providerDesc, { color: theme.textSecondary }]}>
                {ent.description} · Pronote + Messagerie
              </Text>
            </View>
          </Pressable>
        ))}
      </View>

      {/* Direct Pronote section */}
      <Text style={[styles.sectionLabel, { color: theme.textTertiary, marginTop: Spacing.lg }]}>
        CONNEXION DIRECTE
      </Text>
      <View style={styles.providers}>
        <Pressable
          style={({ pressed }) => [
            styles.providerCard,
            {
              backgroundColor: theme.surface,
              borderColor: pressed ? theme.accent : theme.border,
            },
          ]}
          onPress={() => {
            Alert.alert("Pronote", "Comment souhaitez-vous vous connecter ?", [
              {
                text: "QR code (recommandé)",
                onPress: () => router.push("/auth/qrcode"),
              },
              {
                text: "Identifiants",
                onPress: () => router.push("/auth/pronote"),
              },
              { text: "Annuler", style: "cancel" },
            ]);
          }}
        >
          <View style={[styles.iconBox, { backgroundColor: theme.surfaceElevated }]}>
            <Text style={[styles.iconText, { color: theme.accent }]}>P</Text>
          </View>
          <View style={styles.textBlock}>
            <Text style={[styles.providerLabel, { color: theme.text }]}>
              Pronote direct
            </Text>
            <Text style={[styles.providerDesc, { color: theme.textSecondary }]}>
              QR code ou identifiants (sans ENT)
            </Text>
          </View>
        </Pressable>
      </View>

      <Text style={[styles.privacy, { color: theme.textTertiary }]}>
        🔒 Connexion sécurisée. Vos identifiants ne sont jamais stockés
        par nōto. — seuls des tokens chiffrés restent sur votre appareil.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: Spacing.lg,
    paddingTop: Spacing.xl,
  },
  title: {
    fontSize: FontSize.xxl,
    fontFamily: Fonts.bold,
    marginBottom: Spacing.lg,
  },
  sectionLabel: {
    fontSize: 11,
    fontFamily: Fonts.medium,
    letterSpacing: 1.5,
    marginBottom: Spacing.sm,
  },
  providers: {
    gap: Spacing.sm,
  },
  providerCard: {
    flexDirection: "row",
    alignItems: "center",
    borderRadius: BorderRadius.lg,
    padding: 16,
    borderWidth: 1,
    gap: Spacing.md,
  },
  iconBox: {
    width: 40,
    height: 40,
    borderRadius: BorderRadius.lg,
    justifyContent: "center",
    alignItems: "center",
  },
  iconEmoji: {
    fontSize: 20,
  },
  iconText: {
    fontSize: 18,
    fontFamily: Fonts.monoBold,
  },
  textBlock: {
    flex: 1,
    gap: 2,
  },
  providerLabel: {
    fontSize: FontSize.lg - 1,
    fontFamily: Fonts.semiBold,
  },
  providerDesc: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
  },
  privacy: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
    marginTop: Spacing.xxl,
    textAlign: "center",
    lineHeight: 16,
  },
});
