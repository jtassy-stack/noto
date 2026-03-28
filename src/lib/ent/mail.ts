import * as SecureStore from "expo-secure-store";

// TODO: Update this URL after deploying the server to Vercel
const MAIL_API_URL = "https://server-pi-seven-31.vercel.app/api/mail";

const ENT_MAIL_CREDS_KEY = "noto_ent_mail_creds";

export interface MailCredentials {
  email: string;
  password: string;
}

export interface MailMessage {
  id: number;
  subject: string;
  from: string;
  to: string[];
  date: string;
  unread: boolean;
  flagged: boolean;
  hasAttachment: boolean;
  body?: string;
}

export interface InboxResult {
  messages: MailMessage[];
  total: number;
  unseen: number;
  page: number;
  pageSize: number;
}

// --- Credential storage ---

export async function saveMailCredentials(creds: MailCredentials): Promise<void> {
  await SecureStore.setItemAsync(ENT_MAIL_CREDS_KEY, JSON.stringify(creds));
}

export async function getMailCredentials(): Promise<MailCredentials | null> {
  const raw = await SecureStore.getItemAsync(ENT_MAIL_CREDS_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as MailCredentials;
}

export async function clearMailCredentials(): Promise<void> {
  await SecureStore.deleteItemAsync(ENT_MAIL_CREDS_KEY);
}

// --- API calls ---

async function mailFetch(creds: MailCredentials, action: string, extra?: Record<string, unknown>) {
  const response = await fetch(MAIL_API_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: creds.email, password: creds.password, action, ...extra }),
  });

  if (!response.ok) {
    const err = await response.json().catch(() => ({ error: `HTTP ${response.status}` }));
    throw new Error((err as { error: string }).error);
  }

  return response.json();
}

export async function fetchInbox(creds: MailCredentials, page = 0): Promise<InboxResult> {
  return mailFetch(creds, "inbox", { page }) as Promise<InboxResult>;
}

export async function fetchMessage(creds: MailCredentials, messageId: number): Promise<MailMessage> {
  return mailFetch(creds, "message", { messageId, folder: "INBOX" }) as Promise<MailMessage>;
}

export async function fetchUnreadCount(creds: MailCredentials): Promise<{ unseen: number; total: number }> {
  return mailFetch(creds, "unread") as Promise<{ unseen: number; total: number }>;
}
