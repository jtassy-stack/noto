import * as AuthSession from "expo-auth-session";
import * as WebBrowser from "expo-web-browser";
import * as SecureStore from "expo-secure-store";
import * as Crypto from "expo-crypto";
import type { EntProvider } from "./providers";

WebBrowser.maybeCompleteAuthSession();

const ENT_TOKEN_KEY = "noto_ent_tokens";
const ENT_PROVIDER_KEY = "noto_ent_provider_id";

export interface EntTokens {
  accessToken: string;
  refreshToken: string;
  idToken: string;
  expiresAt: number;
  providerId: string;
}

function getDiscovery(provider: EntProvider): AuthSession.DiscoveryDocument {
  const base = `${provider.authBaseUrl}/realms/${provider.realm}/protocol/openid-connect`;
  return {
    authorizationEndpoint: `${base}/auth`,
    tokenEndpoint: `${base}/token`,
    revocationEndpoint: `${base}/logout`,
    userInfoEndpoint: `${base}/userinfo`,
  };
}

/**
 * Full OAuth login flow using WebBrowser.
 * Opens the system browser, user logs in, we intercept the redirect.
 */
export async function loginWithEnt(provider: EntProvider): Promise<EntTokens> {
  // Generate PKCE challenge
  const codeVerifier = generateCodeVerifier();
  const codeChallenge = await generateCodeChallenge(codeVerifier);

  // Use the ENT's own redirect URI — this is what Keycloak accepts
  // We'll use Expo's auth session to intercept it
  const redirectUri = AuthSession.makeRedirectUri({ scheme: "noto" });
  console.log("[nōto] Using redirect_uri:", redirectUri);

  const discovery = getDiscovery(provider);

  const authUrl = new URL(discovery.authorizationEndpoint!);
  authUrl.searchParams.set("client_id", provider.clientId);
  authUrl.searchParams.set("response_type", "code");
  authUrl.searchParams.set("scope", "openid");
  authUrl.searchParams.set("redirect_uri", redirectUri);
  authUrl.searchParams.set("code_challenge", codeChallenge);
  authUrl.searchParams.set("code_challenge_method", "S256");
  authUrl.searchParams.set("approval_prompt", "force");

  console.log("[nōto] Opening auth URL:", authUrl.toString().substring(0, 100) + "...");

  // Open browser for login
  const result = await WebBrowser.openAuthSessionAsync(
    authUrl.toString(),
    redirectUri
  );

  if (result.type !== "success") {
    throw new Error(`Auth cancelled (${result.type})`);
  }

  // Extract code from redirect URL
  const resultUrl = new URL(result.url);
  const code = resultUrl.searchParams.get("code");
  if (!code) {
    const error = resultUrl.searchParams.get("error_description") || resultUrl.searchParams.get("error");
    throw new Error(`No auth code received: ${error ?? "unknown error"}`);
  }

  console.log("[nōto] Got auth code, exchanging for tokens...");

  // Exchange code for tokens
  const tokenResponse = await AuthSession.exchangeCodeAsync(
    {
      clientId: provider.clientId,
      code,
      redirectUri,
      extraParams: { code_verifier: codeVerifier },
    },
    discovery
  );

  const tokens: EntTokens = {
    accessToken: tokenResponse.accessToken,
    refreshToken: tokenResponse.refreshToken ?? "",
    idToken: tokenResponse.idToken ?? "",
    expiresAt: Date.now() + (tokenResponse.expiresIn ?? 300) * 1000,
    providerId: provider.id,
  };

  await saveTokens(tokens);
  await SecureStore.setItemAsync(ENT_PROVIDER_KEY, provider.id);

  console.log("[nōto] ENT tokens saved, expires:", new Date(tokens.expiresAt).toISOString());
  return tokens;
}

// --- PKCE helpers ---

function generateCodeVerifier(): string {
  const bytes = Crypto.getRandomBytes(32);
  return base64UrlEncode(bytes);
}

async function generateCodeChallenge(verifier: string): Promise<string> {
  const digest = await Crypto.digestStringAsync(
    Crypto.CryptoDigestAlgorithm.SHA256,
    verifier,
    { encoding: Crypto.CryptoEncoding.BASE64 }
  );
  // Convert standard base64 to base64url
  return digest.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncode(bytes: Uint8Array): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let result = "";
  for (let i = 0; i < bytes.length; i++) {
    result += chars[bytes[i]! % chars.length];
  }
  return result;
}

// --- Token management ---

export async function refreshEntTokens(provider: EntProvider): Promise<EntTokens | null> {
  const stored = await getStoredTokens();
  if (!stored?.refreshToken) return null;

  const discovery = getDiscovery(provider);

  try {
    const response = await AuthSession.refreshAsync(
      { clientId: provider.clientId, refreshToken: stored.refreshToken },
      discovery
    );

    const tokens: EntTokens = {
      accessToken: response.accessToken,
      refreshToken: response.refreshToken ?? stored.refreshToken,
      idToken: response.idToken ?? stored.idToken,
      expiresAt: Date.now() + (response.expiresIn ?? 300) * 1000,
      providerId: provider.id,
    };

    await saveTokens(tokens);
    return tokens;
  } catch (e) {
    console.warn("[nōto] ENT token refresh failed:", e);
    return null;
  }
}

export async function getValidAccessToken(provider: EntProvider): Promise<string | null> {
  let tokens = await getStoredTokens();
  if (!tokens) return null;

  if (Date.now() > tokens.expiresAt - 60000) {
    tokens = await refreshEntTokens(provider);
    if (!tokens) return null;
  }

  return tokens.accessToken;
}

async function saveTokens(tokens: EntTokens): Promise<void> {
  await SecureStore.setItemAsync(ENT_TOKEN_KEY, JSON.stringify(tokens));
}

export async function getStoredTokens(): Promise<EntTokens | null> {
  const raw = await SecureStore.getItemAsync(ENT_TOKEN_KEY);
  if (!raw) return null;
  return JSON.parse(raw) as EntTokens;
}

export async function getStoredProviderId(): Promise<string | null> {
  return SecureStore.getItemAsync(ENT_PROVIDER_KEY);
}

export async function clearEntTokens(): Promise<void> {
  await SecureStore.deleteItemAsync(ENT_TOKEN_KEY);
  await SecureStore.deleteItemAsync(ENT_PROVIDER_KEY);
}

export function isEntConnected(tokens: EntTokens | null): boolean {
  return !!tokens && Date.now() < tokens.expiresAt;
}
