import { useState, useMemo, useCallback } from "react";
import { View, Text, Pressable, StyleSheet } from "react-native";
import { Tabs, router } from "expo-router";
import { useFocusEffect } from "@react-navigation/native";
import {
  Home, BarChart2, Calendar, ClipboardList, Mail,
  FileText, Camera, BookOpen,
} from "lucide-react-native";
import { useTheme } from "@/hooks/useTheme";
import { ChildrenContext } from "@/hooks/useChildren";
import { ChildSwitcher } from "@/components/ui/ChildSwitcher";
import { useAccountData } from "@/hooks/useAccountData";
import { Fonts, FontSize, Spacing } from "@/constants/theme";

export default function TabLayout() {
  const theme = useTheme();
  const { children, loading, reload } = useAccountData();
  const [activeChildId, setActiveChildId] = useState("");

  useFocusEffect(
    useCallback(() => {
      reload();
    }, [reload])
  );

  const effectiveChildId = activeChildId || children[0]?.id || "";
  const activeChild = children.find((c) => c.id === effectiveChildId) ?? null;
  const isEnt = activeChild?.source === "ent";

  const childrenCtx = useMemo(
    () => ({
      children,
      activeChild,
      setActiveChildId,
    }),
    [children, activeChild]
  );

  // Adaptive tab config based on child source
  const tabConfig = {
    grades: {
      title: isEnt ? "Blog" : "Notes",
      icon: isEnt ? FileText : BarChart2,
    },
    schedule: {
      title: isEnt ? "Photos" : "EDT",
      icon: isEnt ? Camera : Calendar,
    },
    homework: {
      title: isEnt ? "Cahier" : "Devoirs",
      icon: isEnt ? BookOpen : ClipboardList,
    },
  };

  function LucideIcon({ icon: Icon, focused }: { icon: typeof Home; focused: boolean }) {
    return (
      <Icon
        size={20}
        color={focused ? theme.accent : theme.textTertiary}
        strokeWidth={1.8}
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
          <Pressable
            onPress={() => router.push("/auth/")}
            hitSlop={12}
          >
            <Text style={[styles.addButtonText, { color: theme.textTertiary }]}>+</Text>
          </Pressable>
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
            tabBarIcon: ({ focused }) => <LucideIcon icon={Home} focused={focused} />,
          }}
        />
        <Tabs.Screen
          name="grades"
          options={{
            title: tabConfig.grades.title,
            tabBarIcon: ({ focused }) => <LucideIcon icon={tabConfig.grades.icon} focused={focused} />,
          }}
        />
        <Tabs.Screen
          name="schedule"
          options={{
            title: tabConfig.schedule.title,
            tabBarIcon: ({ focused }) => <LucideIcon icon={tabConfig.schedule.icon} focused={focused} />,
          }}
        />
        <Tabs.Screen
          name="homework"
          options={{
            title: tabConfig.homework.title,
            tabBarIcon: ({ focused }) => <LucideIcon icon={tabConfig.homework.icon} focused={focused} />,
          }}
        />
        <Tabs.Screen
          name="messages"
          options={{
            title: "Messages",
            tabBarIcon: ({ focused }) => <LucideIcon icon={Mail} focused={focused} />,
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
  addButtonText: {
    fontSize: 22,
    fontFamily: Fonts.regular,
  },
});
