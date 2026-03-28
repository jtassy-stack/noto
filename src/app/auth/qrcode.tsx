import { useState, useRef } from "react";
import {
  View,
  Text,
  TextInput,
  Pressable,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from "react-native";
import { CameraView, useCameraPermissions } from "expo-camera";
import { router } from "expo-router";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { authenticateWithQRCode, mapChildren } from "@/lib/pronote/client";
import { saveAccount, saveChildren } from "@/lib/database/repository";

type Step = "scan" | "pin" | "loading";

export default function QRCodeLoginScreen() {
  const theme = useTheme();
  const [permission, requestPermission] = useCameraPermissions();
  const [step, setStep] = useState<Step>("scan");
  const [qrData, setQrData] = useState<unknown>(null);
  const [pin, setPin] = useState("");
  const [error, setError] = useState<string | null>(null);
  const scannedRef = useRef(false);

  async function handleBarCodeScanned({ data }: { data: string }) {
    if (scannedRef.current) return;
    scannedRef.current = true;

    try {
      const parsed = JSON.parse(data);
      setQrData(parsed);
      setStep("pin");
    } catch {
      setError("QR code invalide. Utilisez le QR code généré par l'app Pronote.");
      scannedRef.current = false;
    }
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
      const children = mapChildren(session);

      await saveAccount({
        id: session.information.id.toString(),
        provider: "pronote",
        displayName: session.user.name,
        instanceUrl: session.information.url,
        createdAt: Date.now(),
      });

      await saveChildren(children);
      router.replace("/");
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : "Erreur inconnue";
      setError(`Connexion échouée : ${message}`);
      setStep("pin");
    }
  }

  // Permission not yet determined
  if (!permission) {
    return (
      <View style={[styles.center, { backgroundColor: theme.background }]}>
        <ActivityIndicator color={theme.accent} />
      </View>
    );
  }

  // Permission denied
  if (!permission.granted) {
    return (
      <View style={[styles.center, { backgroundColor: theme.background }]}>
        <Text style={[styles.permText, { color: theme.text }]}>
          L'accès à la caméra est nécessaire pour scanner le QR code Pronote.
        </Text>
        <Pressable
          style={[styles.button, { backgroundColor: theme.accent }]}
          onPress={requestPermission}
        >
          <Text style={styles.buttonText}>Autoriser la caméra</Text>
        </Pressable>
      </View>
    );
  }

  // Step: Scan QR code
  if (step === "scan") {
    return (
      <View style={[styles.container, { backgroundColor: theme.background }]}>
        <View style={styles.instructions}>
          <Text style={[styles.title, { color: theme.text }]}>
            Scanner le QR code
          </Text>
          <Text style={[styles.subtitle, { color: theme.textSecondary }]}>
            Depuis l'app Pronote officielle :{"\n"}
            Paramètres → Générer un QR code
          </Text>
        </View>

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
            setStep("scan");
            setQrData(null);
            setPin("");
            setError(null);
            scannedRef.current = false;
          }}
        >
          <Text style={[styles.rescan, { color: theme.accent }]}>
            ← Re-scanner le QR code
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
  instructions: {
    marginBottom: Spacing.lg,
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
  cornerTL: {
    position: "absolute",
    top: 60,
    left: 60,
    width: 30,
    height: 30,
    borderTopWidth: 3,
    borderLeftWidth: 3,
  },
  cornerTR: {
    position: "absolute",
    top: 60,
    right: 60,
    width: 30,
    height: 30,
    borderTopWidth: 3,
    borderRightWidth: 3,
  },
  cornerBL: {
    position: "absolute",
    bottom: 60,
    left: 60,
    width: 30,
    height: 30,
    borderBottomWidth: 3,
    borderLeftWidth: 3,
  },
  cornerBR: {
    position: "absolute",
    bottom: 60,
    right: 60,
    width: 30,
    height: 30,
    borderBottomWidth: 3,
    borderRightWidth: 3,
  },
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
  rescan: {
    fontSize: FontSize.md,
    fontFamily: Fonts.medium,
    marginTop: Spacing.lg,
    textAlign: "center",
  },
  permText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    textAlign: "center",
    lineHeight: 22,
  },
  loadingText: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    marginTop: Spacing.md,
  },
});
