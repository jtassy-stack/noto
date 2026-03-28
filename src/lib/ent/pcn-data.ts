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
  message: string; // HTML with links
  date: string;
  sender?: string;
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

export async function fetchTimeline(creds: ConversationCredentials): Promise<TimelineNotification[]> {
  const data = await pcnFetchJson(creds, "/timeline/lastNotifications") as Record<string, unknown> | null;
  if (!data) return [];
  const raw = (data as Record<string, unknown>).results ?? data;
  const results = Array.isArray(raw) ? (raw as Record<string, unknown>[]) : [];
  if (results.length === 0) return [];

  return results.map((n) => {
    const rawMessage = String(n.message ?? "");
    const plainMessage = stripHtml(rawMessage).replace(/\n/g, " ").replace(/\s+/g, " ");

    return {
      id: String(n._id ?? ""),
      type: String(n.type ?? ""),
      eventType: String(n["event-type"] ?? ""),
      message: plainMessage,
      date: n.date && typeof n.date === "object" && "$date" in (n.date as Record<string, unknown>)
        ? String((n.date as Record<string, string>).$date)
        : String(n.date ?? ""),
      sender: n.params && typeof n.params === "object" ? String((n.params as Record<string, string>).username ?? "") : undefined,
    };
  });
}
