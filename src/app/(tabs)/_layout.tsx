import { Tabs } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { Colors } from "@/constants/theme";

type TabIcon = React.ComponentProps<typeof Ionicons>["name"];

function tabIcon(name: TabIcon, focused: boolean) {
  return (
    <Ionicons
      name={name}
      size={22}
      color={focused ? Colors.accent : Colors.textTertiary}
    />
  );
}

export default function TabLayout() {
  return (
    <Tabs
      screenOptions={{
        tabBarStyle: {
          backgroundColor: Colors.surface,
          borderTopColor: Colors.border,
        },
        tabBarActiveTintColor: Colors.accent,
        tabBarInactiveTintColor: Colors.textTertiary,
        headerStyle: { backgroundColor: Colors.background },
        headerTintColor: Colors.text,
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
          title: "Emploi du temps",
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
