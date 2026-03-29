/**
 * ENTCore Conversation API client.
 * Used by PCN (Paris Classe Numérique) and other Edifice-based ENTs.
 * Direct REST API — no IMAP proxy needed.
 */

import * as SecureStore from "expo-secure-store";
import type { EntProvider } from "./providers";
import type { Child } from "@/types";

const ENT_CONV_CREDS_KEY = "noto_ent_conv_creds";

export interface ConversationCredentials {
  email: string;
  password: string;
  apiBaseUrl: string;
  sessionCookie?: string;
}

export interface ConversationMessage {
  id: string;
  subject: string;
  from: string;
  to: string[];
  date: string;
  body?: string;
  unread: boolean;
  hasAttachment: boolean;
  /** Group names this message was sent to (for filtering by child) */
  groupNames: string[];
}

// --- Credential storage ---

export async function saveConversationCredentials(creds: ConversationCredentials): Promise<void> {
  await SecureStore.setItemAsync(ENT_CONV_CREDS_KEY, JSON.stringify(creds));
}

export async function getConversationCredentials(): Promise<ConversationCredentials | null> {
  const raw = await SecureStore.getItemAsync(ENT_CONV_CREDS_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as ConversationCredentials;
}

export async function clearConversationCredentials(): Promise<void> {
  await SecureStore.deleteItemAsync(ENT_CONV_CREDS_KEY);
}

// --- Session management ---

let activeSession: { apiBaseUrl: string; lastLogin: number } | null = null;

async function ensureSession(creds: ConversationCredentials): Promise<void> {
  // Re-use session if less than 10 minutes old
  if (activeSession && activeSession.apiBaseUrl === creds.apiBaseUrl && Date.now() - activeSession.lastLogin < 10 * 60 * 1000) {
    return;
  }

  await doLogin(creds);
}

async function doLogin(creds: ConversationCredentials): Promise<void> {
  const response = await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });

  if (response.url.includes("/auth/login")) {
    throw new Error("Identifiants incorrects");
  }

  activeSession = { apiBaseUrl: creds.apiBaseUrl, lastLogin: Date.now() };
  console.log("[nōto] PCN session refreshed");
}

async function pcnFetch(creds: ConversationCredentials, path: string): Promise<Response> {
  await ensureSession(creds);

  let res = await fetch(`${creds.apiBaseUrl}${path}`, {
    headers: { Accept: "application/json" },
  });

  // If 401 or HTML (session expired), re-login and retry
  if (res.status === 401 || res.headers.get("content-type")?.includes("text/html")) {
    console.log("[nōto] PCN session expired, re-login...");
    activeSession = null;
    await doLogin(creds);
    res = await fetch(`${creds.apiBaseUrl}${path}`, {
      headers: { Accept: "application/json" },
    });
  }

  return res;
}

// --- Login (public, for initial connection test) ---

export async function loginToENT(
  provider: EntProvider,
  username: string,
  password: string
): Promise<{ sessionCookie: string }> {
  const creds: ConversationCredentials = {
    email: username,
    password,
    apiBaseUrl: provider.apiBaseUrl,
  };

  await doLogin(creds);

  // Test session
  const testRes = await fetch(`${provider.apiBaseUrl}/conversation/count/INBOX`, {
    headers: { Accept: "application/json" },
  });

  console.log("[nōto] PCN session test:", testRes.status);
  const testText = await testRes.text();
  console.log("[nōto] PCN count response:", testText.substring(0, 100));

  if (!testRes.ok || testText.includes("<!DOCTYPE")) {
    throw new Error("Session invalide — vérifiez vos identifiants");
  }

  return { sessionCookie: "" };
}

// --- Children ---

export async function fetchENTChildren(
  provider: EntProvider,
  sessionCookie: string
): Promise<Child[]> {
  const res = await fetch(`${provider.apiBaseUrl}/userbook/api/person`, {
    headers: {
      Accept: "application/json",
      ...(sessionCookie ? { Cookie: sessionCookie } : {}),
    },
  });

  if (!res.ok) {
    console.warn("[nōto] Failed to fetch ENT children:", res.status);
    return [];
  }

  const data = await res.json();
  const results: Array<Record<string, unknown>> =
    Array.isArray(data.result) ? data.result : Array.isArray(data) ? data : [];

  // Deduplicate by relatedName and get per-child class via individual lookup
  const seen = new Set<string>();
  const children: Child[] = [];

  for (const entry of results) {
    const name = String(entry.relatedName ?? "");
    const relatedId = String(entry.relatedId ?? "");
    if (!name || seen.has(name)) continue;
    seen.add(name);

    const match = name.match(/^([A-ZÀ-ÖÙ-Ý\s]+)\s+(.+)$/);
    const firstName = match ? match[2]!.trim() : name;
    const lastName = match ? match[1]!.trim() : "";

    // Fetch the child's own class via /userbook/api/person?id=<childId>
    let className = "";
    let schoolName = "";
    if (relatedId) {
      try {
        const childRes = await fetch(`${provider.apiBaseUrl}/userbook/api/person?id=${relatedId}`, {
          headers: {
            Accept: "application/json",
            ...(sessionCookie ? { Cookie: sessionCookie } : {}),
          },
        });
        if (childRes.ok) {
          const childData = await childRes.json();
          const childEntry = childData.result?.[0] ?? childData[0] ?? childData;
          const schools = childEntry.schools as Array<{ classes?: string[]; name?: string }> | undefined;
          const school = schools?.[0];
          className = school?.classes?.[0] ?? "";
          schoolName = school?.name ?? "";
        }
      } catch (e) {
        console.warn("[nōto] Failed to fetch class for", firstName, e);
      }
    }

    children.push({
      id: `ent-${name.replace(/\s/g, "-").toLowerCase()}`,
      accountId: `ent-${provider.id}`,
      firstName,
      lastName,
      className: className || schoolName,
      source: "ent",
      hasGrades: false,
      hasSchedule: false,
      hasHomework: false,
      hasMessages: true,
    });
  }

  console.log("[nōto] ENT children:", children.map(c => c.firstName));
  return children;
}

// --- API calls ---

export async function fetchConversationInbox(
  creds: ConversationCredentials,
  page = 0
): Promise<{ messages: ConversationMessage[]; count: number }> {
  const inboxRes = await pcnFetch(creds, `/conversation/list/INBOX?page=${page}&pageSize=20`);
  if (!inboxRes.ok) throw new Error(`Erreur messagerie (${inboxRes.status})`);

  const data = await inboxRes.json();
  const messages: ConversationMessage[] = Array.isArray(data)
    ? data.map(mapConversationMessage)
    : [];

  let count = 0;
  try {
    const countRes = await pcnFetch(creds, "/conversation/count/INBOX");
    if (countRes.ok) {
      const countData = await countRes.json();
      count = typeof countData.count === "number" ? countData.count : 0;
    }
  } catch {}

  return { messages, count };
}

export async function fetchConversationMessage(
  creds: ConversationCredentials,
  messageId: string
): Promise<ConversationMessage> {
  console.log("[nōto] fetchConversationMessage:", messageId);

  // Login + fetch in one chain to ensure cookie persists
  const loginRes = await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });
  console.log("[nōto] Message login:", loginRes.status);

  const msgRes = await fetch(`${creds.apiBaseUrl}/conversation/message/${messageId}`, {
    headers: { Accept: "application/json" },
  });

  console.log("[nōto] Message response:", msgRes.status);
  const text = await msgRes.text();
  console.log("[nōto] Message preview:", text.substring(0, 150));

  if (text.includes("<!DOCTYPE") || !msgRes.ok) {
    throw new Error(`Impossible de charger le message`);
  }

  const msg = JSON.parse(text);
  return mapConversationMessage(msg as Record<string, unknown>);
}

function mapConversationMessage(msg: Record<string, unknown>): ConversationMessage {
  const displayNames = msg.displayNames as Array<[string, string, boolean]> | undefined;

  // From: first non-group entry in displayNames
  const fromEntry = displayNames?.find(dn => dn[2] === false);
  const fromName = fromEntry?.[1] ?? String(msg.from ?? "Inconnu");

  // Group names: entries where isGroup === true
  const groupNames = displayNames
    ?.filter(dn => dn[2] === true)
    .map(dn => dn[1]) ?? [];

  return {
    id: String(msg.id ?? ""),
    subject: String(msg.subject ?? "(sans objet)"),
    from: fromName,
    to: Array.isArray(msg.to) ? (msg.to as string[]) : [],
    date: msg.date ? new Date(Number(msg.date)).toISOString() : new Date().toISOString(),
    body: String(msg.body ?? ""),
    unread: Boolean(msg.unread),
    hasAttachment: Boolean(msg.hasAttachment),
    groupNames,
  };
}

/**
 * Filter messages relevant to a specific child based on their className.
 * A message is relevant if:
 * - It's sent to a group that contains the child's class name
 * - OR it's sent to the whole school (contains school name)
 * - OR it has no group (direct message)
 */
export function filterMessagesByChild(
  messages: ConversationMessage[],
  childClassName: string
): ConversationMessage[] {
  if (!childClassName) return messages;

  // Extract the class part (e.g., "CM1 - CM2 A" from "CM1 - CM2 A - M. Lucas TOLOTTA")
  const classParts = childClassName.split(" - ").slice(0, -1).join(" - ") || childClassName;

  return messages.filter(msg => {
    // No groups → direct message → show to all
    if (msg.groupNames.length === 0) return true;

    return msg.groupNames.some(group => {
      // School-wide message (contains "POLY", "école", etc.)
      if (group.includes("POLY") || group.includes("école") || group.includes("DOMBASLE")) return true;
      // Class-specific: check if group contains the child's full class name
      if (classParts && group.includes(classParts)) return true;
      return false;
    });
  });
}
