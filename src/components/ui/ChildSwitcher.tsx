import { View, Text, Pressable, StyleSheet, ScrollView } from "react-native";
import { Fonts, FontSize, Spacing, BorderRadius } from "@/constants/theme";
import { useTheme } from "@/hooks/useTheme";
import { useChildren } from "@/hooks/useChildren";

export function ChildSwitcher() {
  const theme = useTheme();
  const { children, activeChild, setActiveChildId } = useChildren();

  if (children.length === 0) return null;

  return (
    <View style={[styles.container, { backgroundColor: theme.background }]}>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.pills}
      >
        {children.map((child) => {
          const isActive = child.id === activeChild?.id;
          return (
            <Pressable
              key={child.id}
              onPress={() => setActiveChildId(child.id)}
              style={[
                styles.pill,
                {
                  backgroundColor: isActive
                    ? theme.accent
                    : theme.surfaceElevated,
                  borderColor: isActive ? theme.accent : theme.border,
                },
              ]}
            >
              <Text
                style={[
                  styles.pillText,
                  {
                    color: isActive ? "#FFFFFF" : theme.text,
                    fontFamily: isActive ? Fonts.semiBold : Fonts.regular,
                  },
                ]}
              >
                {child.firstName}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
    paddingBottom: Spacing.sm,
  },
  pills: {
    flexDirection: "row",
    gap: Spacing.sm,
  },
  pill: {
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: BorderRadius.full,
    borderWidth: 1,
  },
  pillText: {
    fontSize: 13,
  },
});
