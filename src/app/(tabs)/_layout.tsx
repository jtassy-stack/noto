import { Tabs } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { useTheme } from "@/hooks/useTheme";

type TabIcon = React.ComponentProps<typeof Ionicons>["name"];

export default function TabLayout() {
  const theme = useTheme();

  function tabIcon(name: TabIcon, focused: boolean) {
    return (
      <Ionicons
        name={name}
        size={22}
        color={focused ? theme.accent : theme.textTertiary}
      />
    );
  }

  return (
    <Tabs
      screenOptions={{
        tabBarStyle: {
          backgroundColor: theme.tabBarBg,
          borderTopColor: theme.tabBarBorder,
        },
        tabBarActiveTintColor: theme.accent,
        tabBarInactiveTintColor: theme.textTertiary,
        tabBarLabelStyle: { fontFamily: "Inter_500Medium", fontSize: 11 },
        headerStyle: { backgroundColor: theme.background },
        headerTintColor: theme.text,
        headerTitleStyle: { fontFamily: "Inter_600SemiBold" },
        headerShadowVisible: false,
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
          tabBarIcon: ({ focused }) =>
            tabIcon("stats-chart-outline", focused),
        }}
      />
      <Tabs.Screen
        name="schedule"
        options={{
          title: "EDT",
          tabBarIcon: ({ focused }) =>
            tabIcon("calendar-outline", focused),
        }}
      />
      <Tabs.Screen
        name="homework"
        options={{
          title: "Devoirs",
          tabBarIcon: ({ focused }) =>
            tabIcon("book-outline", focused),
        }}
      />
      <Tabs.Screen
        name="messages"
        options={{
          title: "Messages",
          tabBarIcon: ({ focused }) =>
            tabIcon("mail-outline", focused),
        }}
      />
    </Tabs>
  );
}
