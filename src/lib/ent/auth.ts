import * as WebBrowser from "expo-web-browser";
import * as SecureStore from "expo-secure-store";
import type { EntProvider } from "./providers";

const ENT_SESSION_KEY = "noto_ent_session";
const ENT_PROVIDER_KEY = "noto_ent_provider_id";

export interface EntSession {
  providerId: string;
  expiresAt: number;
  userName?: string;
  apiBaseUrl: string;
}

/**
 * Login to ENT via browser.
 * Opens the ENT login page in a system browser. User logs in manually.
 * After login, the browser redirects back and RN cookie jar has the session.
 *
 * We use the ENT's own OAuth redirect flow — the user logs into Keycloak,
 * Keycloak redirects to psn.monlycee.net/oauth2/callback which sets cookies,
 * and we capture that the flow completed.
 */
export async function loginWithBrowser(provider: EntProvider): Promise<EntSession> {
  console.log("[nōto] Opening ENT login in browser:", provider.apiBaseUrl);

  // Open the ENT homepage — it will redirect to Keycloak for login
  // After login, Keycloak redirects back to psn.monlycee.net with session cookies
  const result = await WebBrowser.openAuthSessionAsync(
    `${provider.apiBaseUrl}`,
    `${provider.apiBaseUrl}` // prefix match — close browser when we're back on the ENT
  );

  console.log("[nōto] Browser result:", result.type);

  if (result.type !== "success" && result.type !== "cancel") {
    // On iOS, "cancel" means the user closed the browser manually
    // which is fine if they already logged in
  }

  // After the browser closes, check if we have a valid session
  // by trying to fetch userinfo. RN cookie jar should have the cookies.
  console.log("[nōto] Checking session after browser...");

  const sessionValid = await testSession(provider);

  if (!sessionValid) {
    throw new Error("La connexion n'a pas abouti. Réessayez.");
  }

  const session: EntSession = {
    providerId: provider.id,
    expiresAt: Date.now() + 24 * 60 * 60 * 1000,
    apiBaseUrl: provider.apiBaseUrl,
  };

  await saveSession(session);
  await SecureStore.setItemAsync(ENT_PROVIDER_KEY, provider.id);

  console.log("[nōto] ENT session saved");
  return session;
}

/**
 * Test if the current cookie jar has a valid ENT session.
 */
async function testSession(provider: EntProvider): Promise<boolean> {
  try {
    // Try the messages endpoint — if we get JSON, we're in
    const msgEndpoint = provider.messagingType === "zimbra"
      ? "/zimbra/count/INBOX?unread=true"
      : "/conversation/count/INBOX?unread=true";

    const response = await fetch(`${provider.apiBaseUrl}${msgEndpoint}`, {
      headers: { Accept: "application/json" },
    });

    console.log("[nōto] Session test status:", response.status);
    const text = await response.text();
    console.log("[nōto] Session test body:", text.substring(0, 100));

    // If we get JSON with a count, session is valid
    if (response.ok && !text.includes("<!DOCTYPE")) {
      return true;
    }

    return false;
  } catch (e) {
    console.warn("[nōto] Session test error:", e);
    return false;
  }
}

/**
 * Make an authenticated request to the ENT API.
 * Relies on React Native's cookie jar.
 */
export async function entFetch(provider: EntProvider, path: string): Promise<Response> {
  const response = await fetch(`${provider.apiBaseUrl}${path}`, {
    headers: { Accept: "application/json" },
  });

  if (response.status === 401 || response.status === 302) {
    throw new Error("ENT session expired");
  }

  if (!response.ok) {
    throw new Error(`ENT API error: ${response.status}`);
  }

  return response;
}

// --- Session storage ---

async function saveSession(session: EntSession): Promise<void> {
  await SecureStore.setItemAsync(ENT_SESSION_KEY, JSON.stringify(session));
}

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
