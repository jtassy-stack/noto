import * as SecureStore from "expo-secure-store";
import type { EntProvider } from "./providers";

const ENT_SESSION_KEY = "noto_ent_session";
const ENT_PROVIDER_KEY = "noto_ent_provider_id";

export interface EntSession {
  cookies: string;
  providerId: string;
  expiresAt: number;
  userName?: string;
}

/**
 * Login to ENT using username/password.
 * This mirrors the Python monlycee library approach:
 * POST /auth/login with email + password, capture session cookies.
 */
export async function loginWithCredentials(
  provider: EntProvider,
  username: string,
  password: string
): Promise<EntSession> {
  console.log("[nōto] ENT login to", provider.apiBaseUrl);

  // Step 1: POST /auth/login to get session cookies
  const loginUrl = `${provider.apiBaseUrl}/auth/login`;

  const formBody = new URLSearchParams();
  formBody.append("email", username);
  formBody.append("password", password);

  const response = await fetch(loginUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: formBody.toString(),
    redirect: "manual", // Don't follow redirects — we want the cookies
    credentials: "include",
  });

  console.log("[nōto] ENT login response status:", response.status);

  // Accept 200, 301, 302 as success (login redirects are normal)
  if (response.status !== 200 && response.status !== 301 && response.status !== 302) {
    if (response.status === 401) {
      throw new Error("Identifiants incorrects");
    }
    throw new Error(`Erreur de connexion (${response.status})`);
  }

  // Extract cookies from response
  const setCookies = response.headers.get("set-cookie") ?? "";
  console.log("[nōto] Got cookies:", setCookies.substring(0, 100));

  if (!setCookies) {
    // In React Native, cookies might be handled automatically
    // Try to fetch userinfo to verify the session works
    console.log("[nōto] No set-cookie header, trying session validation...");
  }

  // Step 2: Validate session by fetching user info
  const userInfoUrl = `${provider.apiBaseUrl}/auth/oauth2/userinfo`;
  const userResponse = await fetch(userInfoUrl, {
    headers: setCookies ? { Cookie: setCookies } : {},
    credentials: "include",
  });

  let userName: string | undefined;
  if (userResponse.ok) {
    try {
      const userInfo = await userResponse.json() as Record<string, unknown>;
      userName = String(userInfo.username ?? userInfo.login ?? "");
      console.log("[nōto] ENT user:", userName);
    } catch { /* ignore parse errors */ }
  }

  const session: EntSession = {
    cookies: setCookies,
    providerId: provider.id,
    expiresAt: Date.now() + 24 * 60 * 60 * 1000, // 24h
    userName,
  };

  await saveSession(session);
  await SecureStore.setItemAsync(ENT_PROVIDER_KEY, provider.id);

  console.log("[nōto] ENT session saved");
  return session;
}

/**
 * Make an authenticated request to the ENT API.
 */
export async function entFetch(provider: EntProvider, path: string): Promise<Response> {
  const session = await getStoredSession();
  if (!session) throw new Error("Not authenticated to ENT");

  const response = await fetch(`${provider.apiBaseUrl}${path}`, {
    headers: {
      Cookie: session.cookies,
      Accept: "application/json",
    },
    credentials: "include",
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
