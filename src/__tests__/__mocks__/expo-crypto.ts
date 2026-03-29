export function randomUUID(): string {
  return "test-uuid-" + Math.random().toString(36).substring(7);
}

export function getRandomBytes(size: number): Uint8Array {
  return new Uint8Array(size).map(() => Math.floor(Math.random() * 256));
}

export enum CryptoDigestAlgorithm {
  SHA256 = "SHA-256",
}

export enum CryptoEncoding {
  BASE64 = "base64",
}

export async function digestStringAsync(): Promise<string> {
  return "mock-digest";
}
