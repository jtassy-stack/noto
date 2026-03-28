import * as SecureStore from "expo-secure-store";
import type { EntProvider } from "./providers";

const ENT_SESSION_KEY = "noto_ent_session";
const ENT_PROVIDER_KEY = "noto_ent_provider_id";

export interface EntSession {
  providerId: string;
  expiresAt: number;
  apiBaseUrl: string;
  useCookieJar: boolean;
  cachedMessages?: string;
  cachedUnreadCount?: string;
}

/**
 * Save ENT session (called from WebView after successful login).
 */
export async function saveEntSession(session: EntSession): Promise<void> {
  await SecureStore.setItemAsync(ENT_SESSION_KEY, JSON.stringify(session));
  await SecureStore.setItemAsync(ENT_PROVIDER_KEY, session.providerId);
}

/**
 * Make an authenticated request to the ENT API.
 * Uses React Native's shared cookie jar (sharedCookiesEnabled in WebView).
 */
export async function entFetch(provider: EntProvider, path: string): Promise<Response> {
  const response = await fetch(`${provider.apiBaseUrl}${path}`, {
    headers: { Accept: "application/json" },
    credentials: "include",
  });

  if (response.status === 401) {
    throw new Error("ENT session expired");
  }

  if (!response.ok) {
    throw new Error(`ENT API error: ${response.status}`);
  }

  return response;
}

// --- Session storage ---

export async function getStoredSession(): Promise<EntSession | null> {
  const raw = await SecureStore.getItemAsync(ENT_SESSION_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as EntSession;
}

export async function getStoredProviderId(): Promise<string | null> {
  return SecureStore.getItemAsync(ENT_PROVIDER_KEY);
}

export async function clearEntSession(): Promise<void> {
  await SecureStore.deleteItemAsync(ENT_SESSION_KEY);
  await SecureStore.deleteItemAsync(ENT_PROVIDER_KEY);
}

export function isEntConnected(session: EntSession | null): boolean {
  return !!session && Date.now() < session.expiresAt;
}
