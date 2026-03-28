/**
 * PCN data fetcher — blogs + timeline for ENT children.
 * Uses ENTCore REST API with session cookies from login.
 */

import type { ConversationCredentials } from "./conversation";

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

async function pcnFetch(creds: ConversationCredentials, path: string): Promise<Response> {
  // Login first to get fresh session
  await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });

  return fetch(`${creds.apiBaseUrl}${path}`, {
    headers: { Accept: "application/json" },
  });
}

export async function fetchBlogs(creds: ConversationCredentials): Promise<BlogPost[]> {
  const res = await pcnFetch(creds, "/blog/list/all");
  if (!res.ok) return [];

  const data = await res.json();
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
  const res = await pcnFetch(creds, "/timeline/lastNotifications");
  if (!res.ok) return [];

  const data = await res.json();
  const results: Record<string, unknown>[] = data.results || data;
  if (!Array.isArray(results)) return [];

  return results.map((n) => {
    // Strip HTML tags from message for display
    const rawMessage = String(n.message ?? "");
    const plainMessage = rawMessage
      .replace(/<[^>]*>/g, "")
      .replace(/\n/g, " ")
      .replace(/\s+/g, " ")
      .trim();

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
