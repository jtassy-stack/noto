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

// --- Favorites ---

export async function addFavorite(id: string, type: string, title: string, childId?: string): Promise<void> {
  const db = await getDatabase();
  await db.runAsync(
    "INSERT OR REPLACE INTO favorites (id, type, title, child_id) VALUES (?, ?, ?, ?)",
    [id, type, title, childId ?? null]
  );
}

export async function removeFavorite(id: string): Promise<void> {
  const db = await getDatabase();
  await db.runAsync("DELETE FROM favorites WHERE id = ?", [id]);
}

export async function isFavorite(id: string): Promise<boolean> {
  const db = await getDatabase();
  const rows = await db.getAllAsync<{ id: string }>("SELECT id FROM favorites WHERE id = ?", [id]);
  return rows.length > 0;
}

export async function getFavoritesByType(type: string, childId?: string): Promise<Array<{ id: string; title: string }>> {
  const db = await getDatabase();
  const query = childId
    ? "SELECT id, title FROM favorites WHERE type = ? AND (child_id = ? OR child_id IS NULL) ORDER BY created_at DESC"
    : "SELECT id, title FROM favorites WHERE type = ? ORDER BY created_at DESC";
  const params = childId ? [type, childId] : [type];
  return db.getAllAsync<{ id: string; title: string }>(query, params);
}

// --- Photo cache ---

export interface CachedPhoto {
  id: string;
  blogId: string;
  imageUrl: string;
  base64Data: string;
  sourceName: string;
  cachedAt: number;
}

const CACHE_EXPIRY_SECONDS = 7 * 24 * 60 * 60; // 7 days

export async function getCachedPhotosForBlogs(blogIds: string[]): Promise<CachedPhoto[]> {
  if (blogIds.length === 0) return [];
  const db = await getDatabase();
  const placeholders = blogIds.map(() => "?").join(",");
  const cutoff = Math.floor(Date.now() / 1000) - CACHE_EXPIRY_SECONDS;
  const rows = await db.getAllAsync<{
    id: string;
    blog_id: string;
    image_url: string;
    base64_data: string;
    source_name: string;
    cached_at: number;
  }>(
    `SELECT * FROM cached_photos WHERE blog_id IN (${placeholders}) AND cached_at > ? ORDER BY id`,
    [...blogIds, cutoff]
  );
  return rows.map((r) => ({
    id: r.id,
    blogId: r.blog_id,
    imageUrl: r.image_url,
    base64Data: r.base64_data,
    sourceName: r.source_name,
    cachedAt: r.cached_at,
  }));
}

export async function saveCachedPhoto(photo: Omit<CachedPhoto, "cachedAt">): Promise<void> {
  const db = await getDatabase();
  await db.runAsync(
    `INSERT OR REPLACE INTO cached_photos (id, blog_id, image_url, base64_data, source_name, cached_at)
     VALUES (?, ?, ?, ?, ?, unixepoch())`,
    [photo.id, photo.blogId, photo.imageUrl, photo.base64Data, photo.sourceName]
  );
}

export async function deleteExpiredPhotos(): Promise<void> {
  const db = await getDatabase();
  const cutoff = Math.floor(Date.now() / 1000) - CACHE_EXPIRY_SECONDS;
  await db.runAsync("DELETE FROM cached_photos WHERE cached_at <= ?", [cutoff]);
}

export async function deleteCachedPhotosForBlog(blogId: string): Promise<void> {
  const db = await getDatabase();
  await db.runAsync("DELETE FROM cached_photos WHERE blog_id = ?", [blogId]);
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
