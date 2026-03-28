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

    // Fetch ALL data as fast as possible — session expires quickly
    // Collect raw data first, save to DB after (saves are local and fast)
    let gradesData: Awaited<ReturnType<typeof fetchGrades>> = [];
    let scheduleData: Awaited<ReturnType<typeof fetchSchedule>> = [];
    let homeworkData: Awaited<ReturnType<typeof fetchHomework>> = [];

    const nextWeekDate = new Date(today.getTime() + 7 * 86400000);
    const twoWeeksDate = new Date(today.getTime() + 14 * 86400000);

    // Fetch schedule FIRST — most likely to work for parent accounts
    try {
      scheduleData = await fetchSchedule(session, today, nextWeekDate);
      console.log(`[nōto] fetched ${scheduleData.length} schedule entries`);
    } catch (err: unknown) {
      const name = err instanceof Error ? err.constructor.name : "Unknown";
      console.warn(`[nōto] schedule error (${name}):`, err instanceof Error ? err.message : err);
    }

    // Fetch homework
    try {
      homeworkData = await fetchHomework(session, today, twoWeeksDate);
      console.log(`[nōto] fetched ${homeworkData.length} homework items`);
    } catch (err: unknown) {
      const name = err instanceof Error ? err.constructor.name : "Unknown";
      console.warn(`[nōto] homework error (${name}):`, err instanceof Error ? err.message : err);
    }

    // Fetch grades last — known to fail with AccessDenied for some parent accounts
    try {
      gradesData = await fetchGrades(session);
      console.log(`[nōto] fetched ${gradesData.length} grades`);
    } catch (err: unknown) {
      const name = err instanceof Error ? err.constructor.name : "Unknown";
      console.warn(`[nōto] grades error (${name}):`, err instanceof Error ? err.message : err);
    }

    // NOW save everything to DB (local, doesn't need session)
    if (gradesData.length > 0) await saveGrades(gradesData);
    if (scheduleData.length > 0) await saveSchedule(scheduleData);
    if (homeworkData.length > 0) await saveHomework(homeworkData);

    console.log(`[nōto] saved: ${gradesData.length} grades, ${scheduleData.length} schedule, ${homeworkData.length} homework`);
  }

  await setLastSyncTime(new Date());
  console.log("[nōto] Sync complete");
}
