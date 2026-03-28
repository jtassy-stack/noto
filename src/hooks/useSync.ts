import { useState, useCallback } from "react";
import {
  getSession,
  reconnect,
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
  const [error, setError] = useState<string | null>(null);

  const sync = useCallback(async (childId: string) => {
    setSyncing(true);
    setError(null);

    let session = getSession();

    // Try reconnecting if no active session
    if (!session) {
      console.log("[nōto] No active session, attempting reconnect...");
      session = await reconnect(childId);
      if (!session) {
        setError("Session expirée. Reconnectez-vous.");
        setSyncing(false);
        return;
      }
      console.log("[nōto] Reconnected successfully");
    }

    // Switch to the right child resource
    const resource = session.user.resources.find((r) => r.id === childId);
    if (resource) {
      session.userResource = resource;
    }

    const today = new Date();

    // Sync grades — may fail with AccessDenied if tab not available
    try {
      const grades = await fetchGrades(session);
      if (grades.length > 0) await saveGrades(grades);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "";
      if (!msg.includes("AccessDenied") && !msg.includes("access")) {
        // If session expired during sync, try reconnect once
        if (msg.includes("expired") || msg.includes("SessionExpired")) {
          console.log("[nōto] Session expired during grades sync, reconnecting...");
          session = await reconnect(childId);
          if (session) {
            const resource = session.user.resources.find((r) => r.id === childId);
            if (resource) session.userResource = resource;
            try {
              const grades = await fetchGrades(session);
              if (grades.length > 0) await saveGrades(grades);
            } catch { /* ignore second failure */ }
          }
        } else {
          console.warn("[nōto] Grades sync error:", e);
        }
      } else {
        console.log("[nōto] Grades tab not available for this account");
      }
    }

    // Sync schedule
    try {
      const nextWeek = new Date();
      nextWeek.setDate(today.getDate() + 7);
      const schedule = await fetchSchedule(session!, today, nextWeek);
      if (schedule.length > 0) await saveSchedule(schedule);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "";
      if (!msg.includes("AccessDenied") && !msg.includes("access")) {
        console.warn("[nōto] Schedule sync error:", e);
      } else {
        console.log("[nōto] Schedule tab not available for this account");
      }
    }

    // Sync homework
    try {
      const twoWeeks = new Date();
      twoWeeks.setDate(today.getDate() + 14);
      const homework = await fetchHomework(session!, today, twoWeeks);
      if (homework.length > 0) await saveHomework(homework);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : "";
      if (!msg.includes("AccessDenied") && !msg.includes("access")) {
        console.warn("[nōto] Homework sync error:", e);
      } else {
        console.log("[nōto] Homework tab not available for this account");
      }
    }

    const now = new Date();
    await setLastSyncTime(now);
    setLastSync(now);
    setSyncing(false);
  }, []);

  return { sync, syncing, lastSync, error };
}
