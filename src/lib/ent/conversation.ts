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

// --- Login ---

export async function loginToENT(
  provider: EntProvider,
  username: string,
  password: string
): Promise<{ sessionCookie: string }> {
  const loginUrl = `${provider.apiBaseUrl}/auth/login`;

  const response = await fetch(loginUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`,
    redirect: "follow",
  });

  console.log("[nōto] PCN login status:", response.status, response.url);

  // If redirected back to login page, credentials are wrong
  if (response.url.includes("/auth/login")) {
    throw new Error("Identifiants incorrects");
  }

  // Extract cookies — React Native may handle them automatically
  const setCookie = response.headers.get("set-cookie") ?? "";

  // Test session by fetching message count
  const testUrl = `${provider.apiBaseUrl}/conversation/count/INBOX`;
  const testRes = await fetch(testUrl, {
    headers: {
      Accept: "application/json",
      ...(setCookie ? { Cookie: setCookie } : {}),
    },
  });

  console.log("[nōto] PCN session test:", testRes.status);
  const testText = await testRes.text();
  console.log("[nōto] PCN count response:", testText.substring(0, 100));

  if (!testRes.ok || testText.includes("<!DOCTYPE")) {
    throw new Error("Session invalide — vérifiez vos identifiants");
  }

  return { sessionCookie: setCookie };
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
  const results: Array<{ id: string; relatedName: string; type: string[] }> =
    Array.isArray(data.result) ? data.result : Array.isArray(data) ? data : [];

  // Deduplicate by relatedName (same parent ID appears once per child)
  const seen = new Set<string>();
  const children: Child[] = [];

  for (const entry of results) {
    const name = entry.relatedName;
    if (!name || seen.has(name)) continue;
    seen.add(name);

    // Parse "TASSY Suzanne" → firstName: Suzanne, lastName: TASSY
    const match = name.match(/^([A-ZÀ-ÖÙ-Ý\s]+)\s+(.+)$/);
    const firstName = match ? match[2]!.trim() : name;
    const lastName = match ? match[1]!.trim() : "";

    children.push({
      id: `ent-${name.replace(/\s/g, "-").toLowerCase()}`,
      accountId: `ent-${provider.id}`,
      firstName,
      lastName,
      className: "", // PCN doesn't provide class in this endpoint
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
  // First, login to get fresh session
  const loginRes = await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });

  const setCookie = loginRes.headers.get("set-cookie") ?? "";
  const cookieHeader = setCookie || (creds.sessionCookie ?? "");

  // Fetch inbox
  const inboxUrl = `${creds.apiBaseUrl}/conversation/list/INBOX?page=${page}&pageSize=20`;
  const inboxRes = await fetch(inboxUrl, {
    headers: {
      Accept: "application/json",
      ...(cookieHeader ? { Cookie: cookieHeader } : {}),
    },
  });

  if (!inboxRes.ok) throw new Error(`Erreur messagerie (${inboxRes.status})`);

  const data = await inboxRes.json();
  const messages: ConversationMessage[] = Array.isArray(data)
    ? data.map(mapConversationMessage)
    : [];

  // Fetch count
  let count = 0;
  try {
    const countRes = await fetch(`${creds.apiBaseUrl}/conversation/count/INBOX`, {
      headers: {
        Accept: "application/json",
        ...(cookieHeader ? { Cookie: cookieHeader } : {}),
      },
    });
    if (countRes.ok) {
      const countData = await countRes.json();
      count = typeof countData.count === "number" ? countData.count : (countData ?? 0);
    }
  } catch {}

  return { messages, count };
}

export async function fetchConversationMessage(
  creds: ConversationCredentials,
  messageId: string
): Promise<ConversationMessage> {
  // Login first
  const loginRes = await fetch(`${creds.apiBaseUrl}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `email=${encodeURIComponent(creds.email)}&password=${encodeURIComponent(creds.password)}`,
    redirect: "follow",
  });

  const setCookie = loginRes.headers.get("set-cookie") ?? "";

  const msgRes = await fetch(`${creds.apiBaseUrl}/conversation/message/${messageId}`, {
    headers: {
      Accept: "application/json",
      ...(setCookie ? { Cookie: setCookie } : {}),
    },
  });

  if (!msgRes.ok) throw new Error(`Erreur message (${msgRes.status})`);

  const msg = await msgRes.json();
  return mapConversationMessage(msg);
}

function mapConversationMessage(msg: Record<string, unknown>): ConversationMessage {
  const displayNames = msg.displayNames as string[][] | undefined;
  const fromName = displayNames?.[0]?.[1] ?? String(msg.from ?? "Inconnu");

  return {
    id: String(msg.id ?? ""),
    subject: String(msg.subject ?? "(sans objet)"),
    from: fromName,
    to: Array.isArray(msg.to) ? (msg.to as string[]) : [],
    date: msg.date ? new Date(Number(msg.date)).toISOString() : new Date().toISOString(),
    body: String(msg.body ?? ""),
    unread: Boolean(msg.unread),
    hasAttachment: Boolean(msg.hasAttachment),
  };
}
