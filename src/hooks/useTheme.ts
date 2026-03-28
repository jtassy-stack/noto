import { useColorScheme } from "react-native";
import { LightTheme, DarkTheme, type ThemeColors } from "@/constants/theme";

export function useTheme(): ThemeColors {
  const scheme = useColorScheme();
  return scheme === "dark" ? DarkTheme : LightTheme;
}
