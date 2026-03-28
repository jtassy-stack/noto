import { View, Text, StyleSheet } from "react-native";
import { Colors, FontSize, Spacing } from "@/constants/theme";

export default function GradesScreen() {
  return (
    <View style={styles.container}>
      <Text style={styles.placeholder}>
        Connectez un compte pour voir les notes.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Colors.background,
    justifyContent: "center",
    alignItems: "center",
    padding: Spacing.lg,
  },
  placeholder: {
    fontSize: FontSize.md,
    color: Colors.textTertiary,
    textAlign: "center",
  },
});
