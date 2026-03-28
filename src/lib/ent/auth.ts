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
 * Login to ENT using username/password.
 * React Native handles cookies automatically via its internal cookie jar.
 * After POST /auth/login, subsequent fetch() calls to the same domain
 * will include the session cookies automatically.
 */
export async function loginWithCredentials(
  provider: EntProvider,
  username: string,
  password: string
): Promise<EntSession> {
  console.log("[nōto] ENT login to", provider.apiBaseUrl);

  // Step 1: POST /auth/login
  const loginUrl = `${provider.apiBaseUrl}/auth/login`;
  const formBody = `email=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`;

  const loginResponse = await fetch(loginUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: formBody,
    redirect: "follow", // Follow redirects — RN cookie jar captures cookies along the way
  });

  console.log("[nōto] ENT login status:", loginResponse.status, loginResponse.url);

  // If we ended up on a login page again, credentials were wrong
  if (loginResponse.url.includes("/auth/login")) {
    const text = await loginResponse.text();
    if (text.includes("auth-error") || text.includes("error")) {
      throw new Error("Identifiants incorrects");
    }
  }

  // Step 2: Verify session by fetching user info
  // The cookie jar should now have the session cookie
  console.log("[nōto] Verifying ENT session...");
  const userInfoResponse = await fetch(`${provider.apiBaseUrl}/auth/oauth2/userinfo`, {
    headers: { Accept: "application/json" },
  });

  console.log("[nōto] UserInfo status:", userInfoResponse.status);

  let userName: string | undefined;
  if (userInfoResponse.ok) {
    try {
      const info = await userInfoResponse.json() as Record<string, unknown>;
      userName = String(info.username ?? info.login ?? info.firstName ?? "");
      console.log("[nōto] ENT user:", userName, JSON.stringify(info).substring(0, 200));
    } catch {
      console.log("[nōto] Could not parse userinfo");
    }
  } else {
    console.warn("[nōto] UserInfo failed:", userInfoResponse.status);
    // Session might still work for other endpoints
  }

  // Step 3: Test messaging endpoint
  const msgEndpoint = provider.messagingType === "zimbra"
    ? "/zimbra/count/INBOX?unread=true"
    : "/conversation/count/INBOX?unread=true";

  try {
    const msgResponse = await fetch(`${provider.apiBaseUrl}${msgEndpoint}`, {
      headers: { Accept: "application/json" },
    });
    console.log("[nōto] Messages test:", msgResponse.status, await msgResponse.text().then(t => t.substring(0, 100)));
  } catch (e) {
    console.warn("[nōto] Messages test failed:", e);
  }

  const session: EntSession = {
    providerId: provider.id,
    expiresAt: Date.now() + 24 * 60 * 60 * 1000,
    userName,
    apiBaseUrl: provider.apiBaseUrl,
  };

  await saveSession(session);
  await SecureStore.setItemAsync(ENT_PROVIDER_KEY, provider.id);

  console.log("[nōto] ENT session saved");
  return session;
}

/**
 * Make an authenticated request to the ENT API.
 * Relies on React Native's internal cookie jar — no manual cookie header needed.
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
