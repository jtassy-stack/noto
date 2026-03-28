import * as AuthSession from "expo-auth-session";
import * as WebBrowser from "expo-web-browser";
import * as SecureStore from "expo-secure-store";

WebBrowser.maybeCompleteAuthSession();

const KEYCLOAK_BASE = "https://auth.monlycee.net/realms/IDF/protocol/openid-connect";
const CLIENT_ID = "psn-web-een";
const ENT_TOKEN_KEY = "noto_ent_tokens";

// Discovery document for Keycloak
const discovery: AuthSession.DiscoveryDocument = {
  authorizationEndpoint: `${KEYCLOAK_BASE}/auth`,
  tokenEndpoint: `${KEYCLOAK_BASE}/token`,
  revocationEndpoint: `${KEYCLOAK_BASE}/logout`,
  userInfoEndpoint: `${KEYCLOAK_BASE}/userinfo`,
};

export interface EntTokens {
  accessToken: string;
  refreshToken: string;
  idToken: string;
  expiresAt: number; // unix ms
}

/**
 * Create an OAuth2 auth request with PKCE.
 * Must be called from a React component (uses hooks internally via AuthSession).
 */
export function useEntAuth() {
  const redirectUri = AuthSession.makeRedirectUri({
    scheme: "noto",
    path: "auth/ent-callback",
  });

  const [request, response, promptAsync] = AuthSession.useAuthRequest(
    {
      clientId: CLIENT_ID,
      scopes: ["openid"],
      redirectUri,
      responseType: AuthSession.ResponseType.Code,
      usePKCE: true,
      prompt: AuthSession.Prompt.Login,
    },
    discovery
  );

  return { request, response, promptAsync, redirectUri };
}

/**
 * Exchange authorization code for tokens.
 */
export async function exchangeCodeForTokens(
  code: string,
  codeVerifier: string,
  redirectUri: string
): Promise<EntTokens> {
  const response = await AuthSession.exchangeCodeAsync(
    {
      clientId: CLIENT_ID,
      code,
      redirectUri,
      extraParams: {
        code_verifier: codeVerifier,
      },
    },
    discovery
  );

  const tokens: EntTokens = {
    accessToken: response.accessToken,
    refreshToken: response.refreshToken ?? "",
    idToken: response.idToken ?? "",
    expiresAt: Date.now() + (response.expiresIn ?? 300) * 1000,
  };

  await saveTokens(tokens);
  return tokens;
}

/**
 * Refresh the access token using the refresh token.
 */
export async function refreshEntTokens(): Promise<EntTokens | null> {
  const stored = await getStoredTokens();
  if (!stored?.refreshToken) return null;

  try {
    const response = await AuthSession.refreshAsync(
      {
        clientId: CLIENT_ID,
        refreshToken: stored.refreshToken,
      },
      discovery
    );

    const tokens: EntTokens = {
      accessToken: response.accessToken,
      refreshToken: response.refreshToken ?? stored.refreshToken,
      idToken: response.idToken ?? stored.idToken,
      expiresAt: Date.now() + (response.expiresIn ?? 300) * 1000,
    };

    await saveTokens(tokens);
    return tokens;
  } catch (e) {
    console.warn("[nōto] ENT token refresh failed:", e);
    return null;
  }
}

/**
 * Get a valid access token, refreshing if needed.
 */
export async function getValidAccessToken(): Promise<string | null> {
  let tokens = await getStoredTokens();
  if (!tokens) return null;

  // Refresh if expired (with 60s buffer)
  if (Date.now() > tokens.expiresAt - 60000) {
    tokens = await refreshEntTokens();
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

export async function clearEntTokens(): Promise<void> {
  await SecureStore.deleteItemAsync(ENT_TOKEN_KEY);
}

export function isEntConnected(tokens: EntTokens | null): boolean {
  return !!tokens && Date.now() < tokens.expiresAt;
}
