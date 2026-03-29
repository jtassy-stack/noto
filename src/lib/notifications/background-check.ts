/**
 * Background message checker — privacy-first notifications.
 *
 * How it works:
 * 1. iOS wakes the app every ~15-30min via BackgroundFetch
 * 2. We re-login to PCN/IMAP and check unread message count
 * 3. If count increased since last check → local notification
 * 4. Everything stays on device — zero server involvement
 */

import * as BackgroundFetch from "expo-background-fetch";
import * as TaskManager from "expo-task-manager";
import * as Notifications from "expo-notifications";
import { getMailCredentials, fetchUnreadCount as fetchImapUnread } from "@/lib/ent/mail";
import { getConversationCredentials } from "@/lib/ent/conversation";
import * as SecureStore from "expo-secure-store";

const TASK_NAME = "NOTO_CHECK_MESSAGES";
const LAST_COUNT_KEY = "noto_last_unread_count";

// --- Notification setup ---

export async function setupNotifications(): Promise<void> {
  // Request permissions
  const { status } = await Notifications.requestPermissionsAsync();
  if (status !== "granted") {
    console.log("[nōto] Notification permission denied");
    return;
  }

  // Configure notification behavior
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldShowAlert: true,
      shouldPlaySound: true,
      shouldSetBadge: true,
      shouldShowBanner: true,
      shouldShowList: true,
    }),
  });

  console.log("[nōto] Notifications configured");
}

// --- Background task ---

async function checkForNewMessages(): Promise<BackgroundFetch.BackgroundFetchResult> {
  console.log("[nōto] Background check starting...");

  try {
    let totalUnread = 0;

    // Check PCN (Conversation API)
    const convCreds = await getConversationCredentials();
    if (convCreds) {
      try {
        // Login
        await fetch(`${convCreds.apiBaseUrl}/auth/login`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: `email=${encodeURIComponent(convCreds.email)}&password=${encodeURIComponent(convCreds.password)}`,
          redirect: "follow",
        });

        // Check unread count
        const countRes = await fetch(`${convCreds.apiBaseUrl}/conversation/count/INBOX`, {
          headers: { Accept: "application/json" },
        });

        if (countRes.ok) {
          const data = await countRes.json() as { count?: number };
          const count = data.count ?? 0;
          totalUnread += count;
          console.log("[nōto] PCN unread:", count);
        }
      } catch (e) {
        console.warn("[nōto] PCN check error:", e);
      }
    }

    // Check Mon Lycée (IMAP)
    const imapCreds = await getMailCredentials();
    if (imapCreds) {
      try {
        const result = await fetchImapUnread(imapCreds);
        totalUnread += result.unseen;
        console.log("[nōto] IMAP unread:", result.unseen);
      } catch (e) {
        console.warn("[nōto] IMAP check error:", e);
      }
    }

    // Compare with last known count
    const lastCountStr = await SecureStore.getItemAsync(LAST_COUNT_KEY);
    const lastCount = lastCountStr ? parseInt(lastCountStr, 10) : 0;

    console.log("[nōto] Total unread:", totalUnread, "last:", lastCount);

    if (totalUnread > lastCount) {
      const newMessages = totalUnread - lastCount;

      // Send local notification
      await Notifications.scheduleNotificationAsync({
        content: {
          title: "nōto.",
          body: newMessages === 1
            ? "Vous avez un nouveau message"
            : `Vous avez ${newMessages} nouveaux messages`,
          badge: totalUnread,
          sound: true,
        },
        trigger: null, // immediate
      });

      console.log("[nōto] Notification sent:", newMessages, "new messages");
    }

    // Save current count
    await SecureStore.setItemAsync(LAST_COUNT_KEY, String(totalUnread));

    return totalUnread > lastCount
      ? BackgroundFetch.BackgroundFetchResult.NewData
      : BackgroundFetch.BackgroundFetchResult.NoData;
  } catch (e) {
    console.warn("[nōto] Background check error:", e);
    return BackgroundFetch.BackgroundFetchResult.Failed;
  }
}

// --- Task registration ---

// Define the task (must be at module level, outside components)
TaskManager.defineTask(TASK_NAME, async () => {
  return await checkForNewMessages();
});

export async function registerBackgroundTask(): Promise<void> {
  try {
    const isRegistered = await TaskManager.isTaskRegisteredAsync(TASK_NAME);
    if (isRegistered) {
      console.log("[nōto] Background task already registered");
      return;
    }

    await BackgroundFetch.registerTaskAsync(TASK_NAME, {
      minimumInterval: 15 * 60, // 15 minutes minimum (iOS controls actual frequency)
      stopOnTerminate: false,
      startOnBoot: true,
    });

    console.log("[nōto] Background task registered (15min interval)");
  } catch (e) {
    console.warn("[nōto] Failed to register background task:", e);
  }
}

export async function unregisterBackgroundTask(): Promise<void> {
  try {
    await BackgroundFetch.unregisterTaskAsync(TASK_NAME);
    console.log("[nōto] Background task unregistered");
  } catch {}
}

/**
 * Manual check — can be called from the app to test notifications.
 */
export async function manualCheckMessages(): Promise<{ unread: number; notified: boolean }> {
  const result = await checkForNewMessages();
  const countStr = await SecureStore.getItemAsync(LAST_COUNT_KEY);
  return {
    unread: countStr ? parseInt(countStr, 10) : 0,
    notified: result === BackgroundFetch.BackgroundFetchResult.NewData,
  };
}
