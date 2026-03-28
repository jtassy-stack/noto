import { useState, useMemo, useCallback } from "react";
import { View, Text, Pressable, StyleSheet } from "react-native";
import { Tabs, router } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { useFocusEffect } from "@react-navigation/native";
import { useTheme } from "@/hooks/useTheme";
import { ChildrenContext } from "@/hooks/useChildren";
import { ChildSwitcher } from "@/components/ui/ChildSwitcher";
import { useAccountData } from "@/hooks/useAccountData";
import { Fonts, FontSize, Spacing } from "@/constants/theme";

type TabIcon = React.ComponentProps<typeof Ionicons>["name"];

export default function TabLayout() {
  const theme = useTheme();
  const { children, loading, reload } = useAccountData();
  const [activeChildId, setActiveChildId] = useState("");

  // Reload data when tab gains focus (after login)
  useFocusEffect(
    useCallback(() => {
      reload();
    }, [reload])
  );

  // Auto-select first child when data loads
  const effectiveChildId = activeChildId || children[0]?.id || "";

  const childrenCtx = useMemo(
    () => ({
      children,
      activeChild: children.find((c) => c.id === effectiveChildId) ?? null,
      setActiveChildId,
    }),
    [children, effectiveChildId]
  );

  function tabIcon(name: TabIcon, focused: boolean) {
    return (
      <Ionicons
        name={name}
        size={22}
        color={focused ? theme.accent : theme.textTertiary}
      />
    );
  }

  function HeaderWithSwitcher() {
    return (
      <View style={[styles.header, { backgroundColor: theme.background }]}>
        <View style={styles.headerTop}>
          <Text style={[styles.logo, { color: theme.text }]}>
            n<Text style={{ color: theme.accent }}>ō</Text>to
            <Text style={{ color: theme.accent }}>.</Text>
          </Text>
          {children.length === 0 && !loading && (
            <Pressable
              onPress={() => router.push("/auth/")}
              style={[styles.addButton, { borderColor: theme.accent }]}
            >
              <Text style={[styles.addButtonText, { color: theme.accent }]}>
                + Compte
              </Text>
            </Pressable>
          )}
        </View>
        {children.length > 0 && <ChildSwitcher />}
      </View>
    );
  }

  return (
    <ChildrenContext.Provider value={childrenCtx}>
      <Tabs
        screenOptions={{
          tabBarStyle: {
            backgroundColor: theme.tabBarBg,
            borderTopColor: theme.tabBarBorder,
          },
          tabBarActiveTintColor: theme.accent,
          tabBarInactiveTintColor: theme.textTertiary,
          tabBarLabelStyle: { fontFamily: "Inter_500Medium", fontSize: 11 },
          header: () => <HeaderWithSwitcher />,
        }}
      >
        <Tabs.Screen
          name="index"
          options={{
            title: "Accueil",
            tabBarIcon: ({ focused }) => tabIcon("home-outline", focused),
          }}
        />
        <Tabs.Screen
          name="grades"
          options={{
            title: "Notes",
            tabBarIcon: ({ focused }) => tabIcon("stats-chart-outline", focused),
          }}
        />
        <Tabs.Screen
          name="schedule"
          options={{
            title: "EDT",
            tabBarIcon: ({ focused }) => tabIcon("calendar-outline", focused),
          }}
        />
        <Tabs.Screen
          name="homework"
          options={{
            title: "Devoirs",
            tabBarIcon: ({ focused }) => tabIcon("book-outline", focused),
          }}
        />
        <Tabs.Screen
          name="messages"
          options={{
            title: "Messages",
            tabBarIcon: ({ focused }) => tabIcon("mail-outline", focused),
          }}
        />
      </Tabs>
    </ChildrenContext.Provider>
  );
}

const styles = StyleSheet.create({
  header: {
    paddingTop: 54,
  },
  headerTop: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.xs,
  },
  logo: {
    fontSize: 22,
    fontFamily: Fonts.pixel,
  },
  addButton: {
    borderWidth: 1,
    borderRadius: 4,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  addButtonText: {
    fontSize: FontSize.sm,
    fontFamily: Fonts.medium,
  },
});
