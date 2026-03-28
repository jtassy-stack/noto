import * as pronote from "pawnote";
import {
  fetchGrades,
  fetchSchedule,
  fetchHomework,
} from "./client";
import {
  saveGrades,
  saveSchedule,
  saveHomework,
  setLastSyncTime,
} from "@/lib/database/repository";

/**
 * Sync all data using an already-authenticated session.
 * Call this right after login, while the session is still alive.
 * Runs all fetches in parallel to beat session expiry.
 */
export async function syncWithSession(session: pronote.SessionHandle): Promise<void> {
  const today = new Date();

  for (const resource of session.user.resources) {
    session.userResource = resource;
    console.log(`[nōto] Syncing data for ${resource.name} (${resource.id})...`);

    // Log available tabs with names so we know what this account can access
    const availableTabs: Record<number, string | undefined> = {};
    for (const [loc, tab] of resource.tabs) {
      availableTabs[loc] = tab.defaultPeriod?.name;
    }
    console.log(`[nōto] Available tabs:`, JSON.stringify(availableTabs));

    const nextWeek = new Date(today.getTime() + 7 * 86400000);
    const twoWeeks = new Date(today.getTime() + 14 * 86400000);

    // Run sequentially — Pawnote serializes requests via internal queue
    // Order by priority: grades first (most valuable), then schedule, then homework
    const tasks: { type: string; fn: () => Promise<number> }[] = [
      {
        type: "grades",
        fn: async () => {
          const grades = await fetchGrades(session);
          if (grades.length > 0) await saveGrades(grades);
          return grades.length;
        },
      },
      {
        type: "schedule",
        fn: async () => {
          const schedule = await fetchSchedule(session, today, nextWeek);
          if (schedule.length > 0) await saveSchedule(schedule);
          return schedule.length;
        },
      },
      {
        type: "homework",
        fn: async () => {
          const homework = await fetchHomework(session, today, twoWeeks);
          if (homework.length > 0) await saveHomework(homework);
          return homework.length;
        },
      },
    ];

    for (const task of tasks) {
      try {
        const count = await task.fn();
        console.log(`[nōto] ${task.type}: ${count} items saved`);
      } catch (err: unknown) {
        const name = err instanceof Error ? err.constructor.name : "Unknown";
        const msg = err instanceof Error ? err.message : String(err);
        if (name === "AccessDeniedError" || msg.includes("access")) {
          console.log(`[nōto] ${task.type}: tab not available for parent account`);
        } else if (name === "SessionExpiredError" || msg.includes("expired")) {
          console.warn(`[nōto] ${task.type}: session expired — stopping sync`);
          break; // No point continuing, session is dead
        } else {
          console.warn(`[nōto] ${task.type} error (${name}):`, msg);
        }
      }
    }
  }

  await setLastSyncTime(new Date());
  console.log("[nōto] Sync complete");
}
