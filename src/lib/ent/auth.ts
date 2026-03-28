import * as AuthSession from "expo-auth-session";
import * as WebBrowser from "expo-web-browser";
import * as SecureStore from "expo-secure-store";
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
 * Create an OAuth2 auth request with PKCE for a specific ENT provider.
 */
export function useEntAuth(provider: EntProvider) {
  const discovery = getDiscovery(provider);

  const redirectUri = AuthSession.makeRedirectUri({
    scheme: "noto",
    path: "auth/ent-callback",
  });

  const [request, response, promptAsync] = AuthSession.useAuthRequest(
    {
      clientId: provider.clientId,
      scopes: ["openid"],
      redirectUri,
      responseType: AuthSession.ResponseType.Code,
      usePKCE: true,
      prompt: AuthSession.Prompt.Login,
    },
    discovery
  );

  return { request, response, promptAsync, redirectUri, discovery };
}

/**
 * Exchange authorization code for tokens.
 */
export async function exchangeCodeForTokens(
  provider: EntProvider,
  code: string,
  codeVerifier: string,
  redirectUri: string
): Promise<EntTokens> {
  const discovery = getDiscovery(provider);

  const response = await AuthSession.exchangeCodeAsync(
    {
      clientId: provider.clientId,
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
    providerId: provider.id,
  };

  await saveTokens(tokens);
  await SecureStore.setItemAsync(ENT_PROVIDER_KEY, provider.id);
  return tokens;
}

/**
 * Refresh the access token.
 */
export async function refreshEntTokens(provider: EntProvider): Promise<EntTokens | null> {
  const stored = await getStoredTokens();
  if (!stored?.refreshToken) return null;

  const discovery = getDiscovery(provider);

  try {
    const response = await AuthSession.refreshAsync(
      {
        clientId: provider.clientId,
        refreshToken: stored.refreshToken,
      },
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

/**
 * Get a valid access token, refreshing if needed.
 */
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
