import { useState, useCallback } from "react";
import {
  getSession,
  fetchGrades,
  fetchSchedule,
  fetchHomework,
} from "@/lib/pronote/client";
import {
  saveGrades,
  saveSchedule,
  saveHomework,
  setLastSyncTime,
} from "@/lib/database/repository";

export function useSync() {
  const [syncing, setSyncing] = useState(false);
  const [lastSync, setLastSync] = useState<Date | null>(null);

  const sync = useCallback(async (childId: string) => {
    const session = getSession();
    if (!session) return;

    setSyncing(true);

    try {
      // Switch to the right child resource if multi-children
      const resource = session.user.resources.find((r) => r.id === childId);
      if (resource) {
        session.userResource = resource;
      }

      // Sync grades
      const grades = await fetchGrades(session);
      if (grades.length > 0) await saveGrades(grades);

      // Sync schedule (today + next 7 days)
      const today = new Date();
      const nextWeek = new Date();
      nextWeek.setDate(today.getDate() + 7);
      const schedule = await fetchSchedule(session, today, nextWeek);
      if (schedule.length > 0) await saveSchedule(schedule);

      // Sync homework (next 14 days)
      const twoWeeks = new Date();
      twoWeeks.setDate(today.getDate() + 14);
      const homework = await fetchHomework(session, today, twoWeeks);
      if (homework.length > 0) await saveHomework(homework);

      const now = new Date();
      await setLastSyncTime(now);
      setLastSync(now);
    } catch (e) {
      console.warn("[nōto] Sync error:", e);
    } finally {
      setSyncing(false);
    }
  }, []);

  return { sync, syncing, lastSync };
}
