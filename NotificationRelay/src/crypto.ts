const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function randomToken(byteCount = 32): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteCount));
  return base64url(bytes);
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

export async function encryptString(value: string, masterSecret: string): Promise<string> {
  const key = await encryptionKey(masterSecret);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    encoder.encode(value),
  ));
  return `v1.${base64url(iv)}.${base64url(ciphertext)}`;
}

export async function decryptString(value: string, masterSecret: string): Promise<string> {
  const [version, ivValue, ciphertextValue] = value.split(".");
  if (version !== "v1" || !ivValue || !ciphertextValue) throw new Error("invalid ciphertext");
  const key = await encryptionKey(masterSecret);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: fromBase64url(ivValue) },
    key,
    fromBase64url(ciphertextValue),
  );
  return decoder.decode(plaintext);
}

export async function verifyAppleSignature(rawBody: ArrayBuffer, signature: string | null, secret: string): Promise<boolean> {
  const match = signature?.match(/^hmacsha256=([0-9a-f]{64})$/i);
  if (!match) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = new Uint8Array(await crypto.subtle.sign("HMAC", key, rawBody));
  const supplied = fromHex(match[1]);
  return timingSafeEqual(expected, supplied);
}

export async function appleSignature(rawBody: ArrayBuffer, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return `hmacsha256=${hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, rawBody)))}`;
}

function timingSafeEqual(lhs: Uint8Array, rhs: Uint8Array): boolean {
  if (lhs.byteLength !== rhs.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < lhs.byteLength; index += 1) difference |= lhs[index] ^ rhs[index];
  return difference === 0;
}

async function encryptionKey(secret: string): Promise<CryptoKey> {
  if (secret.length < 32) throw new Error("RELAY_ENCRYPTION_KEY must be at least 32 characters");
  const material = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  return crypto.subtle.importKey("raw", material, "AES-GCM", false, ["encrypt", "decrypt"]);
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function fromHex(value: string): Uint8Array {
  if (value.length % 2 !== 0) return new Uint8Array();
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    const byte = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
    if (!Number.isFinite(byte)) return new Uint8Array();
    bytes[index] = byte;
  }
  return bytes;
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromBase64url(value: string): Uint8Array<ArrayBuffer> {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(base64);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}
