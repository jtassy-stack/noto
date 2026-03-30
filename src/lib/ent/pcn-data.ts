/**
 * PCN data fetcher — blogs + timeline for ENT children.
 * Uses ENTCore REST API with session cookies from login.
 */

import type { ConversationCredentials } from "./conversation";
import { stripHtml } from "@/lib/utils/html";

// Re-use the session management from conversation.ts
async function pcnFetchJson(creds: ConversationCredentials, path: string): Promise<unknown> {
  // Login if needed
  await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });

  const res = await fetch(`${creds.apiBaseUrl}${path}`, {
    headers: { Accept: "application/json" },
  });

  if (!res.ok) return null;
  return res.json();
}

export interface BlogPost {
  id: string;
  title: string;
  modified: string;
  thumbnail?: string;
}

export interface TimelineNotification {
  id: string;
  type: string; // MESSAGERIE, BLOG, SCHOOLBOOK
  eventType: string;
  message: string;
  date: string;
  sender?: string;
  resourceUri?: string;
  /** For SCHOOLBOOK: the word ID extracted from resourceUri */
  wordId?: string;
  /** For SCHOOLBOOK: the word title from params */
  wordTitle?: string;
}

export async function fetchBlogs(creds: ConversationCredentials): Promise<BlogPost[]> {
  const data = await pcnFetchJson(creds, "/blog/list/all");
  if (!Array.isArray(data)) return [];

  return data.map((b: Record<string, unknown>) => ({
    id: String(b._id ?? ""),
    title: String(b.title ?? "").trim(),
    modified: b.modified && typeof b.modified === "object" && "$date" in (b.modified as Record<string, unknown>)
      ? String((b.modified as Record<string, string>).$date)
      : "",
    thumbnail: b.thumbnail ? String(b.thumbnail) : undefined,
  }));
}

// --- Cahier de textes (homeworks) ---

export interface PcnHomeworkEntry {
  id: string;
  subject: string;
  description: string;
  dueDate: string; // ISO date (YYYY-MM-DD)
}

/**
 * Fetch cahier de textes entries from PCN.
 * GET /homeworks/list — returns homework entries for the logged-in parent's children.
 */
export async function fetchHomeworks(creds: ConversationCredentials): Promise<PcnHomeworkEntry[]> {
  const data = await pcnFetchJson(creds, "/homeworks/list");
  if (!data || typeof data !== "object") return [];

  // The API may return { results: [...] } or a direct array
  const raw = Array.isArray(data)
    ? (data as Record<string, unknown>[])
    : Array.isArray((data as Record<string, unknown>).results)
      ? ((data as Record<string, unknown>).results as Record<string, unknown>[])
      : [];

  return raw.map((entry) => {
    // Extract date — may be { "$date": "..." } or a string
    let dueDate = "";
    const rawDate = entry.dueDate ?? entry.date ?? entry.due_date;
    if (rawDate && typeof rawDate === "object" && "$date" in (rawDate as Record<string, unknown>)) {
      dueDate = String((rawDate as Record<string, string>).$date).split("T")[0] ?? "";
    } else if (typeof rawDate === "string") {
      dueDate = rawDate.split("T")[0] ?? "";
    } else if (typeof rawDate === "number") {
      dueDate = new Date(rawDate).toISOString().split("T")[0] ?? "";
    }

    const rawDesc = String(entry.description ?? entry.content ?? entry.title ?? "");
    const description = stripHtml(rawDesc).trim();

    return {
      id: String(entry._id ?? entry.id ?? `hw-${dueDate}-${description.slice(0, 20)}`),
      subject: String(
        (entry.subject && typeof entry.subject === "object"
          ? (entry.subject as Record<string, unknown>).label ?? (entry.subject as Record<string, unknown>).name
          : entry.subject) ?? entry.subjectLabel ?? ""
      ),
      description,
      dueDate,
    };
  }).filter((h) => h.dueDate !== "");
}

// --- Carnet de liaison (schoolbook) ---

export interface SchoolbookWord {
  id: string;
  title: string;
  text: string;
  date: string;
  sender: string;
  acknowledged: boolean;
  category?: string;
}

/**
 * Fetch carnet de liaison entries.
 * GET /schoolbook/list — returns words/entries from teachers for the parent's children.
 */
export async function fetchSchoolbook(creds: ConversationCredentials): Promise<SchoolbookWord[]> {
  // Try /schoolbook/list/0 (paginated) then /schoolbook/list
  let data = await pcnFetchJson(creds, "/schoolbook/list/0");
  if (!data) data = await pcnFetchJson(creds, "/schoolbook/list");
  if (!data) return [];

  const raw = Array.isArray(data)
    ? (data as Record<string, unknown>[])
    : typeof data === "object" && data !== null && Array.isArray((data as Record<string, unknown>).results)
      ? ((data as Record<string, unknown>).results as Record<string, unknown>[])
      : [];

  return raw.map((entry) => {
    let date = "";
    const rawDate = entry.modified ?? entry.created ?? entry.date;
    if (rawDate && typeof rawDate === "object" && "$date" in (rawDate as Record<string, unknown>)) {
      date = String((rawDate as Record<string, string>).$date);
    } else if (typeof rawDate === "string") {
      date = rawDate;
    } else if (typeof rawDate === "number") {
      date = new Date(rawDate).toISOString();
    }

    const rawText = String(entry.text ?? entry.content ?? entry.body ?? "");

    return {
      id: String(entry._id ?? entry.id ?? ""),
      title: String(entry.title ?? entry.subject ?? "").trim(),
      text: stripHtml(rawText).trim(),
      date,
      sender: String(
        (entry.owner && typeof entry.owner === "object" ? (entry.owner as Record<string, unknown>).displayName : null)
          ?? entry.ownerName ?? entry.sender ?? ""
      ),
      acknowledged: Boolean(entry.ack ?? entry.acknowledged ?? false),
      category: entry.category ? String(entry.category) : undefined,
    };
  });
}

/**
 * Fetch a single schoolbook word (carnet de liaison) by ID.
 * GET /schoolbook/word/:id
 */
export interface SchoolbookWordDetail {
  id: string;
  title: string;
  text: string;
  sender: string;
  date: string;
}

/**
 * Fetch all schoolbook words (carnet de liaison) for a specific child.
 * GET /schoolbook/list/0/{entChildId}
 * The entChildId is the ENT user ID, not the nōto child ID.
 */
export async function fetchSchoolbookForChild(creds: ConversationCredentials, entChildId: string): Promise<SchoolbookWordDetail[]> {
  const data = await pcnFetchJson(creds, `/schoolbook/list/0/${entChildId}`);
  if (!Array.isArray(data)) {
    console.log("[nōto] Schoolbook: no data for child", entChildId);
    return [];
  }

  const words = data as Record<string, unknown>[];

  return words.map((entry) => ({
    id: String(entry.id ?? ""),
    title: String(entry.title ?? ""),
    text: String(entry.text ?? entry.content ?? ""),
    sender: String(
      (entry.owner && typeof entry.owner === "object"
        ? (entry.owner as Record<string, unknown>).displayName
        : null) ?? entry.ownerName ?? ""
    ),
    date: entry.modified && typeof entry.modified === "object" && "$date" in (entry.modified as Record<string, unknown>)
      ? String((entry.modified as Record<string, string>).$date)
      : String(entry.modified ?? entry.created ?? ""),
  }));
}

/**
 * Fetch a single schoolbook word by ID from a pre-fetched list.
 */
export async function fetchSchoolbookWord(creds: ConversationCredentials, wordId: string, entChildId: string): Promise<SchoolbookWordDetail | null> {
  const words = await fetchSchoolbookForChild(creds, entChildId);
  return words.find((w) => w.id === wordId) ?? null;
}

export async function fetchTimeline(creds: ConversationCredentials): Promise<TimelineNotification[]> {
  const data = await pcnFetchJson(creds, "/timeline/lastNotifications") as Record<string, unknown> | null;
  if (!data) return [];
  const raw = (data as Record<string, unknown>).results ?? data;
  const results = Array.isArray(raw) ? (raw as Record<string, unknown>[]) : [];
  if (results.length === 0) return [];

  const mapped = results.map((n) => {
    const rawMessage = String(n.message ?? "");
    const plainMessage = stripHtml(rawMessage).replace(/\n/g, " ").replace(/\s+/g, " ");
    const params = (n.params && typeof n.params === "object") ? (n.params as Record<string, unknown>) : {};

    // Extract schoolbook word ID from params.resourceUri: "/schoolbook#/word/49824"
    const resourceUri = params.resourceUri ? String(params.resourceUri) : undefined;
    const wordIdMatch = resourceUri?.match(/\/word\/(\d+)/);

    return {
      id: String(n._id ?? ""),
      type: String(n.type ?? ""),
      eventType: String(n["event-type"] ?? ""),
      message: plainMessage,
      date: n.date && typeof n.date === "object" && "$date" in (n.date as Record<string, unknown>)
        ? String((n.date as Record<string, string>).$date)
        : String(n.date ?? ""),
      sender: params.username ? String(params.username) : undefined,
      resourceUri,
      wordId: wordIdMatch ? wordIdMatch[1] : undefined,
      wordTitle: params.wordTitle ? String(params.wordTitle) : undefined,
    };
  });

  return mapped;
}
