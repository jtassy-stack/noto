import { useState, useMemo } from "react";
import { View, Text, StyleSheet } from "react-native";
import { Tabs } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { useTheme } from "@/hooks/useTheme";
import { ChildrenContext } from "@/hooks/useChildren";
import { ChildSwitcher } from "@/components/ui/ChildSwitcher";
import { Fonts, Spacing } from "@/constants/theme";
import type { Child } from "@/types";

type TabIcon = React.ComponentProps<typeof Ionicons>["name"];

// Mock data — will be replaced by database query
const MOCK_CHILDREN: Child[] = [
  { id: "1", accountId: "a1", firstName: "Emma", lastName: "Dupont", className: "3ème B" },
  { id: "2", accountId: "a1", firstName: "Lucas", lastName: "Dupont", className: "5ème A" },
];

export default function TabLayout() {
  const theme = useTheme();
  const [activeChildId, setActiveChildId] = useState(MOCK_CHILDREN[0]?.id ?? "");

  const childrenCtx = useMemo(
    () => ({
      children: MOCK_CHILDREN,
      activeChild: MOCK_CHILDREN.find((c) => c.id === activeChildId) ?? null,
      setActiveChildId,
    }),
    [activeChildId]
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
        </View>
        <ChildSwitcher />
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
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.xs,
  },
  logo: {
    fontSize: 22,
    fontFamily: Fonts.pixel,
  },
});
