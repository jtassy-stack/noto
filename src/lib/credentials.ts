import * as SecureStore from "expo-secure-store";

const KEY_PREFIX = "noto_cred_";

interface StoredCredential {
  username: string;
  password: string;
  instanceUrl: string;
  provider: string;
}

export async function saveCredential(
  accountId: string,
  credential: StoredCredential
): Promise<void> {
  await SecureStore.setItemAsync(
    `${KEY_PREFIX}${accountId}`,
    JSON.stringify(credential)
  );
}

export async function getCredential(
  accountId: string
): Promise<StoredCredential | null> {
  const raw = await SecureStore.getItemAsync(`${KEY_PREFIX}${accountId}`);
  if (!raw) return null;
  return JSON.parse(raw) as StoredCredential;
}

export async function deleteCredential(accountId: string): Promise<void> {
  await SecureStore.deleteItemAsync(`${KEY_PREFIX}${accountId}`);
}
