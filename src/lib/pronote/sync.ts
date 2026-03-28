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

    // Log available tabs so we know what this account can access
    const availableTabs = Array.from(resource.tabs.keys());
    console.log(`[nōto] Available tabs:`, availableTabs);

    const nextWeek = new Date(today.getTime() + 7 * 86400000);
    const twoWeeks = new Date(today.getTime() + 14 * 86400000);

    // Run ALL fetches in parallel to beat session timeout
    const results = await Promise.allSettled([
      fetchGrades(session).then(async (grades) => {
        if (grades.length > 0) await saveGrades(grades);
        return { type: "grades" as const, count: grades.length };
      }),
      fetchSchedule(session, today, nextWeek).then(async (schedule) => {
        if (schedule.length > 0) await saveSchedule(schedule);
        return { type: "schedule" as const, count: schedule.length };
      }),
      fetchHomework(session, today, twoWeeks).then(async (homework) => {
        if (homework.length > 0) await saveHomework(homework);
        return { type: "homework" as const, count: homework.length };
      }),
    ]);

    for (const result of results) {
      if (result.status === "fulfilled") {
        console.log(`[nōto] ${result.value.type}: ${result.value.count} items saved`);
      } else {
        const err = result.reason;
        const name = err instanceof Error ? err.constructor.name : "Unknown";
        const msg = err instanceof Error ? err.message : String(err);
        if (name === "AccessDeniedError") {
          console.log(`[nōto] Tab not available for parent account (${msg})`);
        } else {
          console.warn(`[nōto] Sync error (${name}):`, msg);
        }
      }
    }
  }

  await setLastSyncTime(new Date());
  console.log("[nōto] Sync complete");
}
