import * as pronote from "pawnote";
import * as SecureStore from "expo-secure-store";
import * as Crypto from "expo-crypto";
import type { Account, Child, Grade, ScheduleEntry, Homework } from "@/types";

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
  // Find stored refresh tokens
  const keys = [`noto_refresh_`];
  // Try all stored credentials
  const allAccounts = await SecureStore.getItemAsync(`noto_refresh_list`);
  if (!allAccounts) {
    // Try legacy format: iterate known usernames from the account
    // For now, scan SecureStore isn't possible, so we store a list
    return null;
  }

  const usernames: string[] = JSON.parse(allAccounts);
  for (const username of usernames) {
    const raw = await SecureStore.getItemAsync(`noto_refresh_${username}`);
    if (!raw) continue;

    const stored = JSON.parse(raw) as {
      token: string;
      username: string;
      url: string;
      kind: number;
    };

    try {
      const { session } = await authenticateWithToken(
        stored.url,
        stored.username,
        stored.token
      );
      return session;
    } catch (e) {
      console.warn("[nōto] Reconnect failed for", username, e);
    }
  }

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

  // Store refresh token for next login
  await SecureStore.setItemAsync(
    `noto_refresh_${refresh.username}`,
    JSON.stringify({
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
    })
  );
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

  // Update stored token
  await SecureStore.setItemAsync(
    `noto_refresh_${refresh.username}`,
    JSON.stringify({
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
    })
  );

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

  await SecureStore.setItemAsync(
    `noto_refresh_${refresh.username}`,
    JSON.stringify({
      token: refresh.token,
      username: refresh.username,
      url: refresh.url,
      kind: refresh.kind,
    })
  );

  return { session, refresh };
}

// --- Data Mapping ---

export function mapChildren(session: pronote.SessionHandle): Child[] {
  // Debug: log what Pronote returns so we can see the data shape
  console.log("[nōto] user.name:", session.user.name);
  console.log("[nōto] resources:", session.user.resources.map(r => ({
    id: r.id, name: r.name, className: r.className, kind: r.kind,
  })));

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
    };
  });
}

export async function fetchGrades(
  session: pronote.SessionHandle,
  period?: pronote.Period
): Promise<Grade[]> {
  // Try multiple tab locations — parent accounts vary
  const tab =
    session.userResource.tabs.get(pronote.TabLocation.Grades) ??
    session.userResource.tabs.get(pronote.TabLocation.Gradebook);

  let p = period ?? tab?.defaultPeriod;

  // Fallback: find any period from any available tab
  if (!p) {
    for (const [, t] of session.userResource.tabs) {
      if (t.defaultPeriod) {
        p = t.defaultPeriod;
        break;
      }
    }
  }

  if (!p) {
    console.log("[nōto] No period found for grades");
    return [];
  }

  console.log("[nōto] Fetching grades for period:", p.name ?? "unknown");
  const overview = await pronote.gradesOverview(session, p);

  return overview.grades.map((g) => ({
    id: g.id,
    childId: session.userResource.id,
    subject: g.subject.name,
    value: g.value.kind === pronote.GradeKind.Grade ? g.value.points : 0,
    outOf: g.outOf.points,
    coefficient: g.coefficient,
    date: g.date.toISOString().split("T")[0]!,
    comment: g.comment,
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
    description: a.description,
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

// --- Instance Discovery ---

export async function checkInstance(url: string) {
  return pronote.instance(url);
}
