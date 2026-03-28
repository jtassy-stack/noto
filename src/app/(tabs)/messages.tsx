import { View, Text, StyleSheet } from "react-native";
import { Fonts, FontSize, Spacing } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";

export default function MessagesScreen() {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <Text style={[styles.placeholder, { color: theme.textTertiary }]}>
        Connectez un compte pour voir les messages.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    padding: Spacing.lg,
  },
  placeholder: {
    fontSize: FontSize.md,
    fontFamily: Fonts.regular,
    textAlign: "center",
  },
});
