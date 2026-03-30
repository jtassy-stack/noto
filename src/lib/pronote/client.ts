import * as pronote from "@niicojs/pawnote";
import * as SecureStore from "expo-secure-store";
import * as Crypto from "expo-crypto";
import type { Account, Child, Grade, ScheduleEntry, Homework } from "@/types";
import { stripHtml } from "@/lib/utils/html";

const DEVICE_UUID_KEY = "noto_device_uuid";

async function getDeviceUUID(): Promise<string> {
  let uuid = await SecureStore.getItemAsync(DEVICE_UUID_KEY);
  if (!uuid) {
    uuid = Crypto.randomUUID();
    await SecureStore.setItemAsync(DEVICE_UUID_KEY, uuid);
  }
  return uuid;
}

// --- Session Management ---

let currentSession: pronote.SessionHandle | null = null;

export function getSession(): pronote.SessionHandle | null {
  return currentSession;
}

/**
 * Re-authenticate using the stored refresh token.
 * Call this when the session expires (SessionExpiredError).
 */
export async function reconnect(accountId: string): Promise<pronote.SessionHandle | null> {
  // Strategy 1: Try token stored by account ID (new format)
  const byAccount = await SecureStore.getItemAsync(`noto_refresh_acct_${accountId}`);
  if (byAccount) {
    console.log("[nōto] Reconnect: found token by account ID", accountId);
    const stored = JSON.parse(byAccount) as { token: string; username: string; url: string; kind: number };
    try {
      const { session } = await authenticateWithToken(stored.url, stored.username, stored.token);
      console.log("[nōto] Reconnect: success via account ID");
      return session;
    } catch (e) {
      console.warn("[nōto] Reconnect: account ID token failed", e);
    }
  }

  // Strategy 2: Try username list (legacy format)
  const allAccounts = await SecureStore.getItemAsync(`noto_refresh_list`);
  if (allAccounts) {
    const usernames: string[] = JSON.parse(allAccounts);
    console.log("[nōto] Reconnect: trying usernames:", usernames);
    for (const username of usernames) {
      const raw = await SecureStore.getItemAsync(`noto_refresh_${username}`);
      if (!raw) continue;
      const stored = JSON.parse(raw) as { token: string; username: string; url: string; kind: number };
      try {
        const { session } = await authenticateWithToken(stored.url, stored.username, stored.token);
        // Backfill account ID key for next time
        await SecureStore.setItemAsync(`noto_refresh_acct_${accountId}`, raw);
        console.log("[nōto] Reconnect: success via username", username);
        return session;
      } catch (e) {
        console.warn("[nōto] Reconnect failed for", username, e);
      }
    }
  }

  console.warn("[nōto] Reconnect: no valid tokens found for account", accountId);
  return null;
}

/**
 * Track usernames for reconnection.
 */
async function trackUsername(username: string): Promise<void> {
  const raw = await SecureStore.getItemAsync("noto_refresh_list");
  const list: string[] = raw ? JSON.parse(raw) : [];
  if (!list.includes(username)) {
    list.push(username);
    await SecureStore.setItemAsync("noto_refresh_list", JSON.stringify(list));
  }
}

// --- Authentication ---

export async function authenticateWithCredentials(
  instanceUrl: string,
  username: string,
  password: string
): Promise<{ session: pronote.SessionHandle; refresh: pronote.RefreshInformation }> {
  const session = pronote.createSessionHandle();
  const deviceUUID = await getDeviceUUID();

  const refresh = await pronote.loginCredentials(session, {
    url: instanceUrl,
    kind: pronote.AccountKind.PARENT,
    username,
    password,
    deviceUUID,
  });

  currentSession = session;

  // Store refresh token for next login (both by username and account ID)
  const tokenData = JSON.stringify({
    token: refresh.token,
    username: refresh.username,
    url: refresh.url,
    kind: refresh.kind,
  });
  await SecureStore.setItemAsync(`noto_refresh_${refresh.username}`, tokenData);
  await SecureStore.setItemAsync(`noto_refresh_acct_${session.information.id}`, tokenData);
  await trackUsername(refresh.username);

  return { session, refresh };
}

export async function authenticateWithToken(
  url: string,
  username: string,
  token: string
): Promise<{ session: pronote.SessionHandle; refresh: pronote.RefreshInformation }> {
  const session = pronote.createSessionHandle();
  const deviceUUID = await getDeviceUUID();

  const refresh = await pronote.loginToken(session, {
    url,
    kind: pronote.AccountKind.PARENT,
    username,
    token,
    deviceUUID,
  });

  currentSession = session;

  // Update stored token (both by username and account ID)
  const tokenData = JSON.stringify({
    token: refresh.token,
    username: refresh.username,
    url: refresh.url,
    kind: refresh.kind,
  });
  await SecureStore.setItemAsync(`noto_refresh_${refresh.username}`, tokenData);
  await SecureStore.setItemAsync(`noto_refresh_acct_${session.information.id}`, tokenData);

  return { session, refresh };
}

export async function authenticateWithQRCode(
  pin: string,
  qrData: unknown
): Promise<{ session: pronote.SessionHandle; refresh: pronote.RefreshInformation }> {
  const session = pronote.createSessionHandle();
  const deviceUUID = await getDeviceUUID();

  const refresh = await pronote.loginQrCode(session, {
    deviceUUID,
    pin,
    qr: qrData,
  });

  currentSession = session;

  const tokenData = JSON.stringify({
    token: refresh.token,
    username: refresh.username,
    url: refresh.url,
    kind: refresh.kind,
  });
  await SecureStore.setItemAsync(`noto_refresh_${refresh.username}`, tokenData);
  await SecureStore.setItemAsync(`noto_refresh_acct_${session.information.id}`, tokenData);
  await trackUsername(refresh.username);

  return { session, refresh };
}

// --- Data Mapping ---

export function mapChildren(session: pronote.SessionHandle): Child[] {
  return session.user.resources.map((r) => {
    // Pronote parent accounts: r.name can be "LASTNAME Firstname" or just "LASTNAME"
    // Try to split on the case boundary (uppercase block = last name, rest = first name)
    const match = r.name.match(/^([A-ZÀ-ÖÙ-Ý\s]+)\s+(.+)$/);
    let firstName: string;
    let lastName: string;

    if (match) {
      // "TASSY Julien" → lastName="TASSY", firstName="Julien"
      lastName = match[1]!.trim();
      firstName = match[2]!.trim();
    } else {
      // Fallback: just use the full name as firstName
      firstName = r.name;
      lastName = "";
    }

    return {
      id: r.id,
      accountId: session.information.id.toString(),
      firstName,
      lastName,
      className: r.className ?? "",
      avatarUri: r.profilePicture?.url,
      source: "pronote" as const,
      hasGrades: true,
      hasSchedule: true,
      hasHomework: true,
      hasMessages: false,
    };
  });
}

export async function fetchGrades(
  session: pronote.SessionHandle,
  period?: pronote.Period
): Promise<Grade[]> {
  // Check if Grades tab (198) is authorized — like Papillon does
  const authorizedTabs = session.user.authorizations.tabs;
  const hasGradesTab = authorizedTabs.includes(pronote.TabLocation.Grades);
  console.log("[nōto] Grades tab authorized:", hasGradesTab, "authorized tabs:", authorizedTabs);

  if (!hasGradesTab) {
    console.log("[nōto] Grades tab not in authorized tabs, skipping");
    return [];
  }

  // Get period from the Grades tab (198) — like Papillon: resources[0].tabs.get(TabLocation.Grades)
  const gradesTab = session.userResource.tabs.get(pronote.TabLocation.Grades);
  if (!gradesTab) {
    console.log("[nōto] Grades tab not found in userResource.tabs");
    return [];
  }

  const p = period ?? gradesTab.defaultPeriod;
  if (!p) {
    // Try latest period from the tab's period list
    const periods = gradesTab.periods;
    if (periods.length === 0) {
      console.log("[nōto] No periods in Grades tab");
      return [];
    }
    console.log("[nōto] Grades tab periods:", periods.map(pp => pp.name));
  }

  const periodToUse = p ?? gradesTab.periods[gradesTab.periods.length - 1];
  if (!periodToUse) return [];

  console.log("[nōto] Calling gradesOverview for period:", periodToUse.name);

  const overview = await pronote.gradesOverview(session, periodToUse);
  console.log("[nōto] gradesOverview returned", overview.grades.length, "grades");

  return overview.grades.map((g) => ({
    id: g.id,
    childId: session.userResource.id,
    subject: g.subject.name,
    value: g.value.kind === pronote.GradeKind.Grade ? g.value.points : 0,
    outOf: g.outOf.points,
    coefficient: g.coefficient,
    date: g.date.toISOString().split("T")[0]!,
    comment: g.comment ? stripHtml(g.comment) : undefined,
    classAverage: g.average?.kind === pronote.GradeKind.Grade ? g.average.points : undefined,
    classMin: g.min?.kind === pronote.GradeKind.Grade ? g.min.points : undefined,
    classMax: g.max?.kind === pronote.GradeKind.Grade ? g.max.points : undefined,
  }));
}

export async function fetchSchedule(
  session: pronote.SessionHandle,
  startDate: Date,
  endDate: Date
): Promise<ScheduleEntry[]> {
  const timetable = await pronote.timetableFromIntervals(session, startDate, endDate);
  pronote.parseTimetable(session, timetable, {
    withCanceledClasses: true,
    withPlannedClasses: true,
    withSuperposedCanceledClasses: false,
  });

  return timetable.classes
    .filter((c): c is pronote.TimetableClassLesson => c.is === "lesson")
    .map((lesson) => ({
      id: lesson.id,
      childId: session.userResource.id,
      subject: lesson.subject?.name ?? "Inconnu",
      teacher: lesson.teacherNames.join(", "),
      room: lesson.classrooms.join(", "),
      startTime: lesson.startDate.toISOString(),
      endTime: lesson.endDate.toISOString(),
      isCancelled: lesson.canceled,
      isModified: !!lesson.status,
      status: lesson.status,
    }));
}

export async function fetchHomework(
  session: pronote.SessionHandle,
  startDate: Date,
  endDate: Date
): Promise<Homework[]> {
  const assignments = await pronote.assignmentsFromIntervals(session, startDate, endDate);

  return assignments.map((a) => ({
    id: a.id,
    childId: session.userResource.id,
    subject: a.subject.name,
    description: stripHtml(a.description),
    dueDate: a.deadline.toISOString().split("T")[0]!,
    isDone: a.done,
  }));
}

export async function fetchAbsences(
  session: pronote.SessionHandle,
  period?: pronote.Period
) {
  const tab = session.userResource.tabs.get(pronote.TabLocation.Notebook);
  const p = period ?? tab?.defaultPeriod;
  if (!p) return { absences: [], delays: [] };

  const nb = await pronote.notebook(session, p);
  return nb;
}

// --- Discussions (Messaging) ---

export interface PronoteMessage {
  id: string;
  subject: string;
  from: string;
  date: string;
  unread: boolean;
  hasAttachment: false;
}

/**
 * Fetch Pronote discussions for the current session.
 * Requires a live session — will attempt reconnection if needed.
 */
export async function fetchDiscussions(accountId: string): Promise<PronoteMessage[]> {
  let session = currentSession;

  // No active session — try to reconnect via stored refresh token
  if (!session) {
    session = await reconnect(accountId);
    if (!session) {
      console.warn("[nōto] Cannot fetch discussions: no session and reconnect failed");
      return [];
    }
  }

  // Check if discussions are authorized
  if (!session.user.authorizations.canReadDiscussions) {
    console.log("[nōto] Discussions not authorized for this account");
    return [];
  }

  try {
    const result = await pronote.discussions(session);

    return result.items.map((d) => ({
      id: d.participantsMessageID,
      subject: d.subject,
      from: d.creator ?? d.recipientName ?? "Pronote",
      date: d.date.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }),
      unread: d.numberOfMessagesUnread > 0,
      hasAttachment: false as const,
    }));
  } catch (e: unknown) {
    // Session expired — try reconnecting once
    if (e instanceof pronote.SessionExpiredError) {
      console.log("[nōto] Session expired, reconnecting...");
      session = await reconnect(accountId);
      if (!session) return [];

      const result = await pronote.discussions(session);
      return result.items.map((d) => ({
        id: d.participantsMessageID,
        subject: d.subject,
        from: d.creator ?? d.recipientName ?? "Pronote",
        date: d.date.toLocaleDateString("fr-FR", { day: "numeric", month: "short" }),
        unread: d.numberOfMessagesUnread > 0,
        hasAttachment: false as const,
      }));
    }
    throw e;
  }
}

// --- Instance Discovery ---

export async function checkInstance(url: string) {
  return pronote.instance(url);
}
