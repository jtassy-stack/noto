import { getValidAccessToken } from "./auth";

const ENT_BASE = "https://psn.monlycee.net";

interface ZimbraMessage {
  id: string;
  subject: string;
  from: string;
  to: string[];
  date: number; // unix ms
  body?: string;
  unread: boolean;
  hasAttachment: boolean;
  state: string;
}

export interface EntMessage {
  id: string;
  subject: string;
  from: string;
  date: string; // ISO
  body: string;
  isRead: boolean;
  hasAttachment: boolean;
}

async function entFetch(path: string): Promise<Response> {
  const token = await getValidAccessToken();
  if (!token) throw new Error("Not authenticated to ENT");

  const response = await fetch(`${ENT_BASE}${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
    },
  });

  if (!response.ok) {
    throw new Error(`ENT API error: ${response.status} ${response.statusText}`);
  }

  return response;
}

/**
 * Get unread message count.
 */
export async function getUnreadCount(): Promise<number> {
  try {
    const res = await entFetch("/zimbra/count/INBOX?unread=true");
    const data = await res.json();
    return typeof data.count === "number" ? data.count : 0;
  } catch {
    return 0;
  }
}

/**
 * List messages from a folder.
 */
export async function listMessages(
  folder: string = "INBOX",
  page: number = 0,
  unread?: boolean
): Promise<EntMessage[]> {
  let url = `/zimbra/list?folder=${encodeURIComponent(folder)}&page=${page}`;
  if (unread !== undefined) url += `&unread=${unread}`;

  const res = await entFetch(url);
  const messages: ZimbraMessage[] = await res.json();

  return messages.map(mapMessage);
}

/**
 * Get a single message with full body.
 */
export async function getMessage(id: string): Promise<EntMessage> {
  const res = await entFetch(`/zimbra/message/${id}`);
  const msg: ZimbraMessage = await res.json();
  return mapMessage(msg);
}

/**
 * Mark messages as read.
 */
export async function markAsRead(ids: string[]): Promise<void> {
  const token = await getValidAccessToken();
  if (!token) return;

  await fetch(`${ENT_BASE}/zimbra/toggleUnread`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ id: ids, unread: false }),
  });
}

function mapMessage(msg: ZimbraMessage): EntMessage {
  return {
    id: msg.id,
    subject: msg.subject ?? "(sans objet)",
    from: msg.from ?? "Inconnu",
    date: new Date(msg.date).toISOString(),
    body: msg.body ?? "",
    isRead: !msg.unread,
    hasAttachment: msg.hasAttachment ?? false,
  };
}
