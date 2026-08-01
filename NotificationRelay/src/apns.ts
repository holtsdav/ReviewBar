import { decryptString } from "./crypto";
import type { InstallationRow, QueuedEvent } from "./types";

export interface APNSClient {
  send(token: string, environment: "sandbox" | "production", payload: object): Promise<APNSResult>;
}

export interface APNSResult {
  status: number;
  reason?: string;
}

export class LiveAPNSClient implements APNSClient {
  constructor(private readonly env: Env) {}

  async send(token: string, environment: "sandbox" | "production", payload: object): Promise<APNSResult> {
    const host = environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${encodeURIComponent(token)}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await apnsJWT(this.env)}`,
        "apns-topic": this.env.APNS_TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    const body: { reason?: string } = await response.json<{ reason?: string }>()
      .catch(() => ({ reason: undefined }));
    return { status: response.status, reason: body.reason };
  }
}

export async function dispatchQueuedEvent(event: QueuedEvent, env: Env, client: APNSClient = new LiveAPNSClient(env)): Promise<void> {
  const installation = await env.DB.prepare(
    "SELECT id, token_hash, apns_token_ciphertext, apns_environment, enabled FROM installations WHERE id = ?",
  ).bind(event.installationID).first<InstallationRow>();
  if (!installation || installation.enabled !== 1) return;

  const token = await decryptString(installation.apns_token_ciphertext, env.RELAY_ENCRYPTION_KEY);
  const result = await client.send(token, installation.apns_environment, notificationPayload(event));
  if (result.status === 200) return;
  if (result.status === 410 || (result.status === 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(result.reason ?? ""))) {
    const now = new Date().toISOString();
    await env.DB.batch([
      env.DB.prepare("UPDATE installations SET enabled = 0, updated_at = ? WHERE id = ?")
        .bind(now, event.installationID),
      env.DB.prepare("UPDATE channels SET enabled = 0, updated_at = ? WHERE installation_id = ?")
        .bind(now, event.installationID),
    ]);
    return;
  }
  if (result.status === 429 || result.status >= 500) throw new Error(`transient APNs status ${result.status}`);
  if (result.status >= 400) throw new Error(`non-success APNs status ${result.status}`);
}

export function notificationPayload(event: QueuedEvent): object {
  const app = event.appName ?? "Your app";
  const state = displayState(event.newState);
  let title = `${app} status changed`;
  let body = state ? `The new state is ${state}.` : "App Store Connect reported a new event.";
  if (event.eventType === "appStoreVersionAppVersionStateUpdated") {
    title = state === "In Review" ? `${app} entered App Review` : state === "Ready for Distribution" ? `${app} was approved` : `${app} release updated`;
    body = state ? `The App Store version is now ${state}.` : body;
  } else if (event.eventType === "buildUploadStateUpdated") {
    title = `${app} build upload updated`;
    body = state ? `The upload is now ${state}.` : body;
  } else if (event.eventType === "buildBetaDetailExternalBuildStateUpdated") {
    title = `${app} TestFlight build updated`;
    body = state ? `External testing is now ${state}.` : body;
  } else if (event.eventType === "betaFeedbackCrashSubmissionCreated") {
    title = `${app} received TestFlight crash feedback`;
    body = "A tester submitted new crash feedback.";
  } else if (event.eventType === "betaFeedbackScreenshotSubmissionCreated") {
    title = `${app} received TestFlight screenshot feedback`;
    body = "A tester submitted new screenshot feedback.";
  }
  return {
    aps: { alert: { title, body }, sound: "default", "thread-id": event.appID },
    reviewbar: { eventID: event.eventID, channelID: event.channelID, eventType: event.eventType },
  };
}

let cachedProviderToken: { value: string; issuedAt: number; keyID: string; teamID: string } | undefined;

async function apnsJWT(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedProviderToken
      && cachedProviderToken.keyID === env.APNS_KEY_ID
      && cachedProviderToken.teamID === env.APNS_TEAM_ID
      && now - cachedProviderToken.issuedAt < 50 * 60) {
    return cachedProviderToken.value;
  }
  const header = encodeJSON({ alg: "ES256", kid: env.APNS_KEY_ID });
  const claims = encodeJSON({ iss: env.APNS_TEAM_ID, iat: now });
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(env.APNS_KEY_P8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  ));
  const value = `${header}.${claims}.${base64url(signature)}`;
  cachedProviderToken = { value, issuedAt: now, keyID: env.APNS_KEY_ID, teamID: env.APNS_TEAM_ID };
  return value;
}

function encodeJSON(value: object): string {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}

function pemBytes(pem: string): ArrayBuffer {
  const base64 = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(base64);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0)).buffer;
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function displayState(state: string | null): string | null {
  if (!state) return null;
  return state.toLowerCase().split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ");
}
