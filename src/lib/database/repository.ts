import { getDatabase } from "./client";
import type { Account, Child, Grade, ScheduleEntry, Homework } from "@/types";

// --- Accounts ---

export async function saveAccount(account: Account): Promise<void> {
  const db = await getDatabase();
  await db.runAsync(
    `INSERT OR REPLACE INTO accounts (id, provider, display_name, instance_url, created_at)
     VALUES (?, ?, ?, ?, ?)`,
    [account.id, account.provider, account.displayName, account.instanceUrl, account.createdAt]
  );
}

export async function getAccounts(): Promise<Account[]> {
  const db = await getDatabase();
  const rows = await db.getAllAsync<{
    id: string;
    provider: string;
    display_name: string;
    instance_url: string;
    created_at: number;
  }>("SELECT * FROM accounts ORDER BY created_at DESC");

  return rows.map((r) => ({
    id: r.id,
    provider: r.provider as Account["provider"],
    displayName: r.display_name,
    instanceUrl: r.instance_url,
    createdAt: r.created_at,
  }));
}

export async function deleteAccount(id: string): Promise<void> {
  const db = await getDatabase();
  await db.runAsync("DELETE FROM accounts WHERE id = ?", [id]);
}

// --- Children ---

export async function saveChildren(children: Child[]): Promise<void> {
  const db = await getDatabase();
  for (const c of children) {
    await db.runAsync(
      `INSERT OR REPLACE INTO children (id, account_id, first_name, last_name, class_name, avatar_uri)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [c.id, c.accountId, c.firstName, c.lastName, c.className, c.avatarUri ?? null]
    );
  }
}

export async function getChildren(): Promise<Child[]> {
  const db = await getDatabase();
  const rows = await db.getAllAsync<{
    id: string;
    account_id: string;
    first_name: string;
    last_name: string;
    class_name: string;
    avatar_uri: string | null;
  }>("SELECT * FROM children ORDER BY first_name");

  return rows.map((r) => ({
    id: r.id,
    accountId: r.account_id,
    firstName: r.first_name,
    lastName: r.last_name,
    className: r.class_name,
    avatarUri: r.avatar_uri ?? undefined,
    // Determine source and capabilities from account ID
    source: r.account_id.startsWith("ent-") ? "ent" as const : "pronote" as const,
    hasGrades: !r.account_id.startsWith("ent-"),
    hasSchedule: !r.account_id.startsWith("ent-"),
    hasHomework: !r.account_id.startsWith("ent-"),
    hasMessages: r.account_id.startsWith("ent-"),
  }));
}

// --- Grades ---

export async function saveGrades(grades: Grade[]): Promise<void> {
  const db = await getDatabase();
  for (const g of grades) {
    await db.runAsync(
      `INSERT OR REPLACE INTO grades (id, child_id, subject, value, out_of, coefficient, date, comment, class_average, class_min, class_max)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [g.id, g.childId, g.subject, g.value, g.outOf, g.coefficient, g.date, g.comment ?? null, g.classAverage ?? null, g.classMin ?? null, g.classMax ?? null]
    );
  }
}

export async function getGradesByChild(childId: string): Promise<Grade[]> {
  const db = await getDatabase();
  const rows = await db.getAllAsync<{
    id: string;
    child_id: string;
    subject: string;
    value: number;
    out_of: number;
    coefficient: number;
    date: string;
    comment: string | null;
    class_average: number | null;
    class_min: number | null;
    class_max: number | null;
  }>("SELECT * FROM grades WHERE child_id = ? ORDER BY date DESC", [childId]);

  return rows.map((r) => ({
    id: r.id,
    childId: r.child_id,
    subject: r.subject,
    value: r.value,
    outOf: r.out_of,
    coefficient: r.coefficient,
    date: r.date,
    comment: r.comment ?? undefined,
    classAverage: r.class_average ?? undefined,
    classMin: r.class_min ?? undefined,
    classMax: r.class_max ?? undefined,
  }));
}

// --- Schedule ---

export async function saveSchedule(entries: ScheduleEntry[]): Promise<void> {
  const db = await getDatabase();
  for (const e of entries) {
    await db.runAsync(
      `INSERT OR REPLACE INTO schedule (id, child_id, subject, teacher, room, start_time, end_time, is_cancelled, is_modified, status)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [e.id, e.childId, e.subject, e.teacher, e.room, e.startTime, e.endTime, e.isCancelled ? 1 : 0, e.isModified ? 1 : 0, e.status ?? null]
    );
  }
}

export async function getScheduleByChild(
  childId: string,
  startDate: string,
  endDate: string
): Promise<ScheduleEntry[]> {
  const db = await getDatabase();
  const rows = await db.getAllAsync<{
    id: string;
    child_id: string;
    subject: string;
    teacher: string;
    room: string;
    start_time: string;
    end_time: string;
    is_cancelled: number;
    is_modified: number;
    status: string | null;
  }>(
    "SELECT * FROM schedule WHERE child_id = ? AND start_time >= ? AND start_time < ? ORDER BY start_time",
    [childId, startDate, endDate]
  );

  return rows.map((r) => ({
    id: r.id,
    childId: r.child_id,
    subject: r.subject,
    teacher: r.teacher,
    room: r.room,
    startTime: r.start_time,
    endTime: r.end_time,
    isCancelled: r.is_cancelled === 1,
    isModified: r.is_modified === 1,
    status: r.status ?? undefined,
  }));
}

// --- Homework ---

export async function saveHomework(items: Homework[]): Promise<void> {
  const db = await getDatabase();
  for (const h of items) {
    await db.runAsync(
      `INSERT OR REPLACE INTO homework (id, child_id, subject, description, due_date, is_done)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [h.id, h.childId, h.subject, h.description, h.dueDate, h.isDone ? 1 : 0]
    );
  }
}

export async function getHomeworkByChild(
  childId: string,
  fromDate?: string
): Promise<Homework[]> {
  const db = await getDatabase();
  const query = fromDate
    ? "SELECT * FROM homework WHERE child_id = ? AND due_date >= ? ORDER BY due_date"
    : "SELECT * FROM homework WHERE child_id = ? ORDER BY due_date DESC LIMIT 20";
  const params = fromDate ? [childId, fromDate] : [childId];

  const rows = await db.getAllAsync<{
    id: string;
    child_id: string;
    subject: string;
    description: string;
    due_date: string;
    is_done: number;
  }>(query, params);

  return rows.map((r) => ({
    id: r.id,
    childId: r.child_id,
    subject: r.subject,
    description: r.description,
    dueDate: r.due_date,
    isDone: r.is_done === 1,
  }));
}

// --- Sync metadata ---

export async function getLastSyncTime(): Promise<Date | null> {
  const db = await getDatabase();
  const rows = await db.getAllAsync<{ value: string }>(
    "SELECT value FROM sync_meta WHERE key = 'last_sync' LIMIT 1"
  );
  return rows.length > 0 ? new Date(rows[0]!.value) : null;
}

export async function setLastSyncTime(time: Date): Promise<void> {
  const db = await getDatabase();
  await db.runAsync(
    `INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('last_sync', ?)`,
    [time.toISOString()]
  );
}
