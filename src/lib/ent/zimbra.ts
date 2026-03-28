import { getValidAccessToken } from "./auth";
import type { EntProvider } from "./providers";

export interface EntMessage {
  id: string;
  subject: string;
  from: string;
  date: string;
  body: string;
  isRead: boolean;
  hasAttachment: boolean;
}

async function entFetch(provider: EntProvider, path: string): Promise<Response> {
  const token = await getValidAccessToken(provider);
  if (!token) throw new Error("Not authenticated to ENT");

  const response = await fetch(`${provider.apiBaseUrl}${path}`, {
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
export async function getUnreadCount(provider: EntProvider): Promise<number> {
  try {
    const endpoint = provider.messagingType === "zimbra"
      ? "/zimbra/count/INBOX?unread=true"
      : "/conversation/count/INBOX?unread=true";
    const res = await entFetch(provider, endpoint);
    const data = await res.json();
    return typeof data.count === "number" ? data.count : 0;
  } catch {
    return 0;
  }
}

/**
 * List messages from inbox.
 */
export async function listMessages(
  provider: EntProvider,
  folder: string = "INBOX",
  page: number = 0
): Promise<EntMessage[]> {
  const endpoint = provider.messagingType === "zimbra"
    ? `/zimbra/list?folder=${encodeURIComponent(folder)}&page=${page}`
    : `/conversation/api/folders/${folder}/messages?page=${page}&page_size=20`;

  const res = await entFetch(provider, endpoint);
  const messages = await res.json();

  if (Array.isArray(messages)) {
    return messages.map(mapMessage);
  }

  return [];
}

/**
 * Get a single message with full body.
 */
export async function getMessage(provider: EntProvider, id: string): Promise<EntMessage> {
  const endpoint = provider.messagingType === "zimbra"
    ? `/zimbra/message/${id}`
    : `/conversation/api/messages/${id}`;

  const res = await entFetch(provider, endpoint);
  const msg = await res.json();
  return mapMessage(msg);
}

function mapMessage(msg: Record<string, unknown>): EntMessage {
  return {
    id: String(msg.id ?? ""),
    subject: String(msg.subject ?? "(sans objet)"),
    from: String(msg.from ?? (Array.isArray(msg.displayNames) ? (msg.displayNames as string[][])?.[0]?.[1] : undefined) ?? "Inconnu"),
    date: new Date(Number(msg.date) || Date.now()).toISOString(),
    body: String(msg.body ?? ""),
    isRead: !msg.unread,
    hasAttachment: Boolean(msg.hasAttachment),
  };
}
