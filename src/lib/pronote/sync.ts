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
 */
export async function syncWithSession(session: pronote.SessionHandle): Promise<void> {
  const today = new Date();

  for (const resource of session.user.resources) {
    session.userResource = resource;
    const childId = resource.id;
    console.log(`[nōto] Syncing data for ${resource.name} (${childId})...`);

    // Grades
    try {
      const grades = await fetchGrades(session);
      if (grades.length > 0) {
        await saveGrades(grades);
        console.log(`[nōto] ${grades.length} grades saved`);
      }
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.name : "";
      if (msg !== "AccessDeniedError") console.warn("[nōto] Grades error:", e);
      else console.log("[nōto] Grades tab not available");
    }

    // Schedule (7 days)
    try {
      const nextWeek = new Date(today.getTime() + 7 * 86400000);
      const schedule = await fetchSchedule(session, today, nextWeek);
      if (schedule.length > 0) {
        await saveSchedule(schedule);
        console.log(`[nōto] ${schedule.length} schedule entries saved`);
      }
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.name : "";
      if (msg !== "AccessDeniedError") console.warn("[nōto] Schedule error:", e);
      else console.log("[nōto] Schedule tab not available");
    }

    // Homework (14 days)
    try {
      const twoWeeks = new Date(today.getTime() + 14 * 86400000);
      const homework = await fetchHomework(session, today, twoWeeks);
      if (homework.length > 0) {
        await saveHomework(homework);
        console.log(`[nōto] ${homework.length} homework items saved`);
      }
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.name : "";
      if (msg !== "AccessDeniedError") console.warn("[nōto] Homework error:", e);
      else console.log("[nōto] Homework tab not available");
    }
  }

  await setLastSyncTime(new Date());
  console.log("[nōto] Sync complete");
}
