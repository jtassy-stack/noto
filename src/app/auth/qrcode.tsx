import { useState, useRef } from "react";
import {
  View,
  Text,
  TextInput,
  Pressable,
  StyleSheet,
  ActivityIndicator,
} from "react-native";
import { CameraView, useCameraPermissions, scanFromURLAsync } from "expo-camera";
import * as ImagePicker from "expo-image-picker";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { authenticateWithQRCode, mapChildren } from "@/lib/pronote/client";
import { saveAccount, saveChildren } from "@/lib/database/repository";
import { syncWithSession } from "@/lib/pronote/sync";

type Step = "choose" | "camera" | "pin" | "loading";

export default function QRCodeLoginScreen() {
  const theme = useTheme();
  const [permission, requestPermission] = useCameraPermissions();
  const [step, setStep] = useState<Step>("choose");
  const [qrData, setQrData] = useState<unknown>(null);
  const [pin, setPin] = useState("");
  const [error, setError] = useState<string | null>(null);
  const scannedRef = useRef(false);

  function processQrString(data: string) {
    try {
      const parsed = JSON.parse(data);
      setQrData(parsed);
      setError(null);
      setStep("pin");
    } catch {
      setError("QR code invalide. Utilisez le QR code généré par l'app Pronote.");
    }
  }

  async function handleBarCodeScanned({ data }: { data: string }) {
    if (scannedRef.current) return;
    scannedRef.current = true;
    processQrString(data);
  }

  async function handlePickImage() {
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ["images"],
      quality: 1,
    });

    if (result.canceled || !result.assets[0]) return;

    setError(null);
    try {
      const scanned = await scanFromURLAsync(result.assets[0].uri, ["qr"]);
      if (scanned.length === 0) {
        setError("Aucun QR code trouvé dans cette image. Assurez-vous que le QR code Pronote est bien visible.");
        return;
      }
      processQrString(scanned[0]!.data);
    } catch {
      setError("Impossible de lire l'image. Réessayez avec une capture d'écran nette du QR code.");
    }
  }

  async function handleOpenCamera() {
    if (!permission?.granted) {
      const result = await requestPermission();
      if (!result.granted) {
        setError("L'accès à la caméra est nécessaire pour scanner le QR code.");
        return;
      }
    }
    scannedRef.current = false;
    setError(null);
    setStep("camera");
  }

  async function handlePinSubmit() {
    if (pin.length !== 4) {
      setError("Le code PIN doit faire 4 chiffres.");
      return;
    }

    setStep("loading");
    setError(null);

    try {
      const { session } = await authenticateWithQRCode(pin, qrData);

      // Save account + children FIRST (sync needs them for foreign keys)
      const children = mapChildren(session);
      await saveAccount({
        id: session.information.id.toString(),
        provider: "pronote",
        displayName: session.user.name,
        instanceUrl: session.information.url,
        createdAt: Date.now(),
      });
      await saveChildren(children);

      // Then sync data while session is still alive
      await syncWithSession(session);

      router.replace("/");
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : "Erreur inconnue";
      setError(`Connexion échouée : ${message}`);
      setStep("pin");
    }
  }

  // Step: Choose method
  if (step === "choose") {
    return (
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <Text style={[styles.title, { color: theme.text }]}>
          QR code Pronote
        </Text>
        <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
          Depuis l'app Pronote officielle :{"\n"}
          Paramètres → Générer un QR code{"\n"}
          Choisissez un code PIN à 4 chiffres.
        </Text>

        <View style={styles.choices}>
          <Pressable
            style={({ pressed }) => [
              styles.choiceCard,
              {
                backgroundColor: theme.surface,
                borderColor: pressed ? theme.accent : theme.border,
              },
            ]}
            onPress={handlePickImage}
          >
            <Text style={[styles.choiceIcon, { color: theme.accent }]}>🖼️</Text>
            <View style={styles.choiceText}>
              <Text style={[styles.choiceTitle, { color: theme.text }]}>
                Depuis la pellicule
              </Text>
              <Text style={[styles.choiceDesc, { color: theme.textSecondary }]}>
                Capture d'écran du QR code
              </Text>
            </View>
          </Pressable>

          <Pressable
            style={({ pressed }) => [
              styles.choiceCard,
              {
                backgroundColor: theme.surface,
                borderColor: pressed ? theme.accent : theme.border,
              },
            ]}
            onPress={handleOpenCamera}
          >
            <Text style={[styles.choiceIcon, { color: theme.accent }]}>📷</Text>
            <View style={styles.choiceText}>
              <Text style={[styles.choiceTitle, { color: theme.text }]}>
                Scanner avec la caméra
              </Text>
              <Text style={[styles.choiceDesc, { color: theme.textSecondary }]}>
                Pointer vers un autre écran
              </Text>
            </View>
          </Pressable>
        </View>

        {error && (
          <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>
        )}

        <Text style={[styles.hint, { color: theme.textTertiary }]}>
          Astuce : faites une capture d'écran du QR code sur un autre appareil,
          puis envoyez-la sur ce téléphone.
        </Text>
      </View>
    );
  }

  // Step: Camera scan
  if (step === "camera") {
    return (
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <View style={styles.cameraContainer}>
          <CameraView
            style={styles.camera}
            facing="back"
            barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
            onBarcodeScanned={handleBarCodeScanned}
          />
          <View style={styles.overlay}>
            <View style={[styles.cornerTL, { borderColor: theme.accent }]} />
            <View style={[styles.cornerTR, { borderColor: theme.accent }]} />
            <View style={[styles.cornerBL, { borderColor: theme.accent }]} />
            <View style={[styles.cornerBR, { borderColor: theme.accent }]} />
          </View>
        </View>

        {error && (
          <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>
        )}

        <Pressable onPress={() => { setStep("choose"); setError(null); }}>
          <Text style={[styles.backLink, { color: theme.accent }]}>
            ← Retour
          </Text>
        </Pressable>
      </View>
    );
  }

  // Step: Enter PIN
  if (step === "pin") {
    return (
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <Text style={[styles.title, { color: theme.text }]}>
          Code PIN
        </Text>
        <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
          Entrez le code PIN à 4 chiffres que vous avez choisi lors de la
          génération du QR code.
        </Text>

        <TextInput
          style={[
            styles.pinInput,
            {
              backgroundColor: theme.surface,
              color: theme.text,
              borderColor: theme.border,
            },
          ]}
          value={pin}
          onChangeText={(t) => setPin(t.replace(/[^0-9]/g, "").slice(0, 4))}
          keyboardType="number-pad"
          maxLength={4}
          placeholder="0000"
          placeholderTextColor={theme.textTertiary}
          autoFocus
          textAlign="center"
        />

        {error && (
          <Text style={[styles.error, { color: theme.crimson }]}>{error}</Text>
        )}

        <Pressable
          style={({ pressed }) => [
            styles.button,
            {
              backgroundColor: theme.accent,
              opacity: pressed ? 0.7 : 1,
            },
          ]}
          onPress={handlePinSubmit}
        >
          <Text style={styles.buttonText}>Se connecter</Text>
        </Pressable>

        <Pressable
          onPress={() => {
            setStep("choose");
            setQrData(null);
            setPin("");
            setError(null);
            scannedRef.current = false;
          }}
        >
          <Text style={[styles.backLink, { color: theme.accent }]}>
            ← Choisir un autre QR code
          </Text>
        </Pressable>
      </View>
    );
  }

  // Step: Loading
  return (
    <View style={[styles.center, { backgroundColor: theme.background }]}>
      <ActivityIndicator color={theme.accent} size="large" />
      <Text style={[styles.loadingText, { color: theme.textSecondary }]}>
        Connexion en cours...
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
  center: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    padding: Spacing.lg,
    gap: Spacing.md,
  },
  title: {
    fontSize: FontSize.xxl,
    fontFamily: Fonts.bold,
  },
  subtitle: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    marginTop: Spacing.sm,
    lineHeight: 22,
  },
  choices: {
    marginTop: Spacing.xl,
    gap: Spacing.sm,
  },
  choiceCard: {
    flexDirection: "row",
    alignItems: "center",
    borderRadius: BorderRadius.lg,
    padding: 18,
    borderWidth: 1,
    gap: Spacing.md,
  },
  choiceIcon: {
    fontSize: 28,
  },
  choiceText: {
    flex: 1,
    gap: 2,
  },
  choiceTitle: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.semiBold,
  },
  choiceDesc: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
  },
  hint: {
    fontSize: FontSize.xs,
    fontFamily: Fonts.regular,
    marginTop: Spacing.xl,
    lineHeight: 16,
    textAlign: "center",
  },
  cameraContainer: {
    width: "100%",
    aspectRatio: 1,
    borderRadius: BorderRadius.lg,
    overflow: "hidden",
    position: "relative",
  },
  camera: {
    flex: 1,
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    justifyContent: "center",
    alignItems: "center",
  },
  cornerTL: { position: "absolute", top: 60, left: 60, width: 30, height: 30, borderTopWidth: 3, borderLeftWidth: 3 },
  cornerTR: { position: "absolute", top: 60, right: 60, width: 30, height: 30, borderTopWidth: 3, borderRightWidth: 3 },
  cornerBL: { position: "absolute", bottom: 60, left: 60, width: 30, height: 30, borderBottomWidth: 3, borderLeftWidth: 3 },
  cornerBR: { position: "absolute", bottom: 60, right: 60, width: 30, height: 30, borderBottomWidth: 3, borderRightWidth: 3 },
  error: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.regular,
    marginTop: Spacing.md,
    lineHeight: 18,
  },
  pinInput: {
    fontSize: 32,
    fontFamily: Fonts.monoBold,
    borderWidth: 1,
    borderRadius: BorderRadius.md,
    paddingVertical: 20,
    marginTop: Spacing.xl,
    letterSpacing: 16,
  },
  button: {
    borderRadius: BorderRadius.md,
    paddingVertical: 16,
    alignItems: "center",
    marginTop: Spacing.lg,
  },
  buttonText: {
    fontSize: FontSize.lg,
    fontFamily: Fonts.semiBold,
    color: "#FFFFFF",
  },
  backLink: {
    fontSize: FontSize.md,
    fontFamily: Fonts.medium,
    marginTop: Spacing.lg,
    textAlign: "center",
  },
  loadingText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    marginTop: Spacing.md,
  },
});
