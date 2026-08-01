import { dispatchQueuedEvent } from "./apns";
import { decryptString, encryptString, randomToken, sha256Hex, verifyAppleSignature } from "./crypto";
import { supportedEventTypes } from "./types";
import type { ChannelRow, InstallationRow, QueuedEvent, SupportedEventType } from "./types";

const securityHeaders = { "strict-transport-security": "max-age=31536000; includeSubDomains" };
const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  ...securityHeaders,
};
const maxWebhookBytes = 256 * 1024;

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof HTTPError) return json({ error: error.message }, error.status);
      return json({ error: "The relay couldn't complete this request." }, 500);
    }
  },

  async queue(batch, env): Promise<void> {
    for (const message of batch.messages) {
      try {
        await dispatchQueuedEvent(message.body, env);
        await env.DB.prepare(
          "UPDATE events SET enqueued = 1 WHERE channel_id = ? AND event_id = ?",
        ).bind(message.body.channelID, message.body.eventID).run();
        message.ack();
      } catch {
        // Returning the durable outbox row to pending lets the cron recover
        // delivery even after Cloudflare exhausts queue retries and moves the
        // message to the DLQ.
        try {
          await env.DB.prepare(
            "UPDATE events SET enqueued = 0, enqueue_attempted_at = ? WHERE channel_id = ? AND event_id = ?",
          ).bind(new Date().toISOString(), message.body.channelID, message.body.eventID).run();
        } catch {
          // The queue retry remains the first recovery path during a D1 outage.
        }
        message.retry();
      }
    }
  },

  async scheduled(_controller, env): Promise<void> {
    await retryPendingEvents(env);
    await env.DB.prepare("DELETE FROM events WHERE julianday(received_at) < julianday('now', '-30 days')").run();
    // Bound server retention if a device loses its local bearer during an
    // initial Keychain failure or never completes webhook confirmation.
    await env.DB.prepare(
      "DELETE FROM channels WHERE apple_webhook_id IS NULL AND julianday(created_at) < julianday('now', '-24 hours')",
    ).run();
    await env.DB.prepare(
      "DELETE FROM installations WHERE NOT EXISTS (SELECT 1 FROM channels WHERE channels.installation_id = installations.id) AND julianday(created_at) < julianday('now', '-24 hours')",
    ).run();
  },
} satisfies ExportedHandler<Env, QueuedEvent>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.protocol !== "https:") throw new HTTPError(400, "HTTPS is required.");
  if (request.method === "GET" && url.pathname === "/health") return json({ status: "ok" });
  if (request.method === "POST" && url.pathname === "/v1/installations") return registerInstallation(request, env);
  if (request.method === "POST" && url.pathname === "/v1/channels") return createChannel(request, env);
  if (request.method === "GET" && url.pathname === "/v1/channels") return listChannels(request, env);
  if (request.method === "GET" && url.pathname === "/v1/events") return listEvents(request, env);
  if (request.method === "PATCH" && url.pathname === "/v1/installations/current/device-token") return rotateDeviceToken(request, env);
  if (request.method === "DELETE" && url.pathname === "/v1/installations/current") return deleteInstallation(request, env);

  const confirm = url.pathname.match(/^\/v1\/channels\/([0-9a-f-]+)\/confirm$/i);
  if (request.method === "PATCH" && confirm) return confirmChannel(request, env, confirm[1]);
  const channel = url.pathname.match(/^\/v1\/channels\/([0-9a-f-]+)$/i);
  if (request.method === "DELETE" && channel) return deleteChannel(request, env, channel[1]);
  const apple = url.pathname.match(/^\/apple\/([0-9a-f-]+)$/i);
  if (request.method === "POST" && apple) return receiveAppleWebhook(request, env, apple[1]);
  throw new HTTPError(404, "Not found.");
}

async function registerInstallation(request: Request, env: Env): Promise<Response> {
  const body = await bodyJSON<{ apnsToken?: unknown; apnsEnvironment?: unknown }>(request, 8 * 1024);
  if (typeof body.apnsToken !== "string" || !/^[0-9a-f]{64,200}$/i.test(body.apnsToken)) {
    throw new HTTPError(400, "A valid APNs device token is required.");
  }
  if (body.apnsEnvironment !== "sandbox" && body.apnsEnvironment !== "production") {
    throw new HTTPError(400, "The APNs environment must be sandbox or production.");
  }
  const id = crypto.randomUUID();
  const token = randomToken(32);
  const now = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO installations (id, token_hash, apns_token_ciphertext, apns_environment, enabled, created_at, updated_at) VALUES (?, ?, ?, ?, 1, ?, ?)",
  ).bind(
    id,
    await sha256Hex(token),
    await encryptString(body.apnsToken.toLowerCase(), env.RELAY_ENCRYPTION_KEY),
    body.apnsEnvironment,
    now,
    now,
  ).run();
  return json({ installationID: id, token }, 201);
}

async function createChannel(request: Request, env: Env): Promise<Response> {
  const installation = await authenticate(request, env);
  const body = await bodyJSON<{ appID?: unknown; appName?: unknown; eventTypes?: unknown }>(request, 32 * 1024);
  if (typeof body.appID !== "string" || !/^[A-Za-z0-9.-]{1,100}$/.test(body.appID)) {
    throw new HTTPError(400, "A valid App Store Connect app identifier is required.");
  }
  if (body.appName != null && (typeof body.appName !== "string" || body.appName.length > 200)) {
    throw new HTTPError(400, "The app name is invalid.");
  }
  const eventTypes = validateEventTypes(body.eventTypes);
  const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM channels WHERE installation_id = ?")
    .bind(installation.id).first<{ count: number }>();
  if ((count?.count ?? 0) >= 50) throw new HTTPError(409, "This installation already monitors the maximum number of apps.");

  const id = crypto.randomUUID();
  const secret = randomToken(48);
  const now = new Date().toISOString();
  try {
    await env.DB.prepare(
      "INSERT INTO channels (id, installation_id, app_id, app_name, secret_ciphertext, event_types_json, enabled, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)",
    ).bind(
      id,
      installation.id,
      body.appID,
      body.appName ?? null,
      await encryptString(secret, env.RELAY_ENCRYPTION_KEY),
      JSON.stringify(eventTypes),
      now,
      now,
    ).run();
  } catch {
    throw new HTTPError(409, "This app already has a notification channel for the installation.");
  }
  const baseURL = validPublicBaseURL(env.PUBLIC_BASE_URL);
  return json({ channelID: id, webhookURL: `${baseURL}/apple/${id}`, secret, eventTypes }, 201);
}

async function confirmChannel(request: Request, env: Env, channelID: string): Promise<Response> {
  const installation = await authenticate(request, env);
  const body = await bodyJSON<{ webhookID?: unknown }>(request, 8 * 1024);
  if (typeof body.webhookID !== "string" || body.webhookID.length > 200 || body.webhookID.length === 0) {
    throw new HTTPError(400, "A valid Apple webhook identifier is required.");
  }
  const result = await env.DB.prepare(
    "UPDATE channels SET apple_webhook_id = ?, updated_at = ? WHERE id = ? AND installation_id = ?",
  ).bind(body.webhookID, new Date().toISOString(), channelID, installation.id).run();
  if (result.meta.changes !== 1) throw new HTTPError(404, "Channel not found.");
  return json({ confirmed: true });
}

async function listChannels(request: Request, env: Env): Promise<Response> {
  const installation = await authenticate(request, env);
  const result = await env.DB.prepare(
    "SELECT id, app_id, app_name, apple_webhook_id, event_types_json, enabled FROM channels WHERE installation_id = ? ORDER BY app_name COLLATE NOCASE",
  ).bind(installation.id).all<Pick<ChannelRow, "id" | "app_id" | "app_name" | "apple_webhook_id" | "event_types_json" | "enabled">>();
  return json({ channels: result.results.map((row) => ({
    channelID: row.id,
    appID: row.app_id,
    appName: row.app_name,
    webhookID: row.apple_webhook_id,
    eventTypes: safeStringArray(row.event_types_json),
    enabled: row.enabled === 1,
  })) });
}

async function deleteChannel(request: Request, env: Env, channelID: string): Promise<Response> {
  const installation = await authenticate(request, env, true);
  const result = await env.DB.prepare("DELETE FROM channels WHERE id = ? AND installation_id = ?")
    .bind(channelID, installation.id).run();
  if (result.meta.changes !== 1) throw new HTTPError(404, "Channel not found.");
  return new Response(null, { status: 204, headers: securityHeaders });
}

async function rotateDeviceToken(request: Request, env: Env): Promise<Response> {
  const installation = await authenticate(request, env, true);
  const body = await bodyJSON<{ apnsToken?: unknown; apnsEnvironment?: unknown }>(request, 8 * 1024);
  if (typeof body.apnsToken !== "string" || !/^[0-9a-f]{64,200}$/i.test(body.apnsToken)) {
    throw new HTTPError(400, "A valid APNs device token is required.");
  }
  if (body.apnsEnvironment !== "sandbox" && body.apnsEnvironment !== "production") {
    throw new HTTPError(400, "The APNs environment must be sandbox or production.");
  }
  await env.DB.prepare(
    "UPDATE installations SET apns_token_ciphertext = ?, apns_environment = ?, enabled = 1, updated_at = ? WHERE id = ?",
  ).bind(
    await encryptString(body.apnsToken.toLowerCase(), env.RELAY_ENCRYPTION_KEY),
    body.apnsEnvironment,
    new Date().toISOString(),
    installation.id,
  ).run();
  await env.DB.prepare("UPDATE channels SET enabled = 1, updated_at = ? WHERE installation_id = ?")
    .bind(new Date().toISOString(), installation.id).run();
  return json({ updated: true });
}

async function deleteInstallation(request: Request, env: Env): Promise<Response> {
  const installation = await authenticate(request, env, true);
  await env.DB.prepare("DELETE FROM installations WHERE id = ?").bind(installation.id).run();
  return new Response(null, { status: 204, headers: securityHeaders });
}

async function listEvents(request: Request, env: Env): Promise<Response> {
  const installation = await authenticate(request, env);
  const url = new URL(request.url);
  const since = url.searchParams.get("since");
  const cursorValue = url.searchParams.get("cursor");
  const cursor = cursorValue ? decodeEventCursor(cursorValue) : null;
  let result: D1Result<EventRow>;
  if (cursorValue && !cursor) throw new HTTPError(400, "The event cursor is invalid.");
  if (cursor) {
    result = await env.DB.prepare(
      `SELECT * FROM events
       WHERE installation_id = ? AND (
         received_at > ? OR
         (received_at = ? AND event_id > ?) OR
         (received_at = ? AND event_id = ? AND channel_id > ?)
       )
       ORDER BY received_at, event_id, channel_id LIMIT 101`,
    ).bind(
      installation.id,
      cursor.receivedAt,
      cursor.receivedAt,
      cursor.eventID,
      cursor.receivedAt,
      cursor.eventID,
      cursor.channelID,
    ).all<EventRow>();
  } else {
    const start = since ? validTimestamp(since) : "0000-01-01T00:00:00.000Z";
    if (since && !start) throw new HTTPError(400, "The event timestamp is invalid.");
    result = await env.DB.prepare(
      "SELECT * FROM events WHERE installation_id = ? AND received_at > ? ORDER BY received_at, event_id, channel_id LIMIT 101",
    ).bind(installation.id, start).all<EventRow>();
  }
  const events = result.results.slice(0, 100);
  const last = events.at(-1);
  return json({
    events,
    nextCursor: result.results.length > 100 && last ? encodeEventCursor(last) : null,
    checkpointCursor: last ? encodeEventCursor(last) : null,
  });
}

async function receiveAppleWebhook(request: Request, env: Env, channelID: string): Promise<Response> {
  const channel = await env.DB.prepare("SELECT * FROM channels WHERE id = ? AND enabled = 1")
    .bind(channelID).first<ChannelRow>();
  if (!channel) throw new HTTPError(404, "Channel not found.");
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > maxWebhookBytes) throw new HTTPError(413, "Webhook body is too large.");
  const rawBody = await request.arrayBuffer();
  if (rawBody.byteLength === 0 || rawBody.byteLength > maxWebhookBytes) throw new HTTPError(413, "Webhook body is empty or too large.");
  const secret = await decryptString(channel.secret_ciphertext, env.RELAY_ENCRYPTION_KEY);
  if (!await verifyAppleSignature(rawBody, request.headers.get("x-apple-signature"), secret)) {
    throw new HTTPError(401, "Invalid Apple webhook signature.");
  }

  let payload: ApplePayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(rawBody)) as ApplePayload;
  } catch {
    throw new HTTPError(400, "Malformed Apple webhook payload.");
  }
  if (!payload?.data || typeof payload.data.id !== "string" || typeof payload.data.type !== "string") {
    throw new HTTPError(400, "Malformed Apple webhook payload.");
  }
  const configuredTypes = safeStringArray(channel.event_types_json);
  const configuredType = inboundToConfiguredType(payload.data.type);
  if (!configuredType) {
    // Apple does not publish the ping envelope schema and can add future
    // signed event types. Acknowledge those without manufacturing an alert.
    return json({ accepted: true, ignored: true }, 202);
  }
  if (configuredType && !configuredTypes.includes(configuredType)) {
    throw new HTTPError(403, "This event type is disabled for the channel.");
  }

  const event = normalizeKnownEvent(payload, channel);
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO events (event_id, installation_id, channel_id, event_type, instance_id, old_state, new_state, authoritative_timestamp, received_at, enqueued) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
  ).bind(
    event.eventID,
    event.installationID,
    event.channelID,
    event.eventType,
    event.instanceID,
    event.oldState,
    event.newState,
    event.authoritativeTimestamp,
    event.receivedAt,
  ).run();
  await claimAndQueue(event, env);
  await env.DB.prepare("DELETE FROM events WHERE julianday(received_at) < julianday('now', '-30 days')").run();
  return json({ accepted: true, duplicate: inserted.meta.changes === 0 }, 202);
}

async function authenticate(request: Request, env: Env, allowDisabled = false): Promise<InstallationRow> {
  const match = request.headers.get("authorization")?.match(/^Bearer ([A-Za-z0-9_-]{40,100})$/);
  if (!match) throw new HTTPError(401, "Installation authentication is required.");
  const installation = await env.DB.prepare(
    "SELECT id, token_hash, apns_token_ciphertext, apns_environment, enabled FROM installations WHERE token_hash = ?",
  ).bind(await sha256Hex(match[1])).first<InstallationRow>();
  if (!installation || (!allowDisabled && installation.enabled !== 1)) {
    throw new HTTPError(401, "Installation authentication is invalid.");
  }
  return installation;
}

function normalizeKnownEvent(payload: ApplePayload, channel: ChannelRow): QueuedEvent {
  const data = payload.data!;
  const attributes = data.attributes ?? {};
  const instance = data.relationships?.instance?.data;
  const eventType = data.type as string;
  let instanceID: string | null = null;
  let oldState: string | null = null;
  let newState: string | null = null;
  let authoritativeTimestamp: string | null = null;

  if (eventType === "appStoreVersionAppVersionStateUpdated") {
    instanceID = requiredInstance(instance, "appStoreVersions");
    oldState = requiredString(attributes.oldValue, "oldValue");
    newState = requiredString(attributes.newValue, "newValue");
    authoritativeTimestamp = requiredTimestamp(attributes.timestamp);
  } else if (eventType === "buildBetaDetailExternalBuildStateUpdated") {
    instanceID = requiredInstance(instance, "buildBetaDetails");
    oldState = requiredString(attributes.oldExternalBuildState, "oldExternalBuildState");
    newState = requiredString(attributes.newExternalBuildState, "newExternalBuildState");
    authoritativeTimestamp = requiredTimestamp(attributes.timestamp);
  } else if (eventType === "buildUploadStateUpdated") {
    instanceID = requiredInstance(instance, "buildUploads");
    newState = requiredString(attributes.newState, "newState");
  } else if (eventType === "betaFeedbackCrashSubmissionCreated") {
    instanceID = requiredInstance(instance, "betaFeedbackCrashSubmissions");
  } else if (eventType === "betaFeedbackScreenshotSubmissionCreated") {
    instanceID = requiredInstance(instance, "betaFeedbackScreenshotSubmissions");
  } else {
    throw new HTTPError(400, "Unsupported known event type.");
  }

  return {
    eventID: data.id as string,
    installationID: channel.installation_id,
    channelID: channel.id,
    appID: channel.app_id,
    appName: channel.app_name,
    eventType,
    instanceID,
    oldState,
    newState,
    authoritativeTimestamp,
    receivedAt: new Date().toISOString(),
  };
}

function requiredInstance(
  instance: { id?: unknown; type?: unknown } | undefined,
  expectedType: string,
): string {
  if (instance?.type !== expectedType) throw new HTTPError(400, "Webhook instance relationship has an unexpected type.");
  return requiredString(instance.id, "instance identifier");
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 200) {
    throw new HTTPError(400, `Webhook ${field} is missing or invalid.`);
  }
  return value;
}

function requiredTimestamp(value: unknown): string {
  if (typeof value !== "string") throw new HTTPError(400, "Webhook timestamp is missing or invalid.");
  const timestamp = validTimestamp(value);
  if (!timestamp) throw new HTTPError(400, "Webhook timestamp is missing or invalid.");
  return timestamp;
}

function encodeEventCursor(row: Pick<EventRow, "received_at" | "event_id" | "channel_id">): string {
  return btoa(`${row.received_at}\n${row.event_id}\n${row.channel_id}`)
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function decodeEventCursor(value: string): { receivedAt: string; eventID: string; channelID: string } | null {
  try {
    const base64 = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
    const [receivedAt, eventID, channelID, extra] = atob(base64).split("\n");
    if (extra !== undefined || !receivedAt || !eventID || !channelID || !validTimestamp(receivedAt)) return null;
    return { receivedAt, eventID, channelID };
  } catch {
    return null;
  }
}

async function retryPendingEvents(env: Env): Promise<void> {
  const result = await env.DB.prepare(
    `SELECT e.*, c.app_id, c.app_name
     FROM events e JOIN channels c ON c.id = e.channel_id
     WHERE (
       (e.enqueued = 0 AND (e.enqueue_attempted_at IS NULL OR julianday(e.enqueue_attempted_at) < julianday('now', '-5 minutes')))
       OR (e.enqueued = 2 AND julianday(e.enqueue_attempted_at) < julianday('now', '-5 minutes'))
     ) AND c.enabled = 1
     ORDER BY e.received_at LIMIT 100`,
  ).all<PendingEventRow>();
  for (const row of result.results) {
    const event: QueuedEvent = {
      eventID: row.event_id,
      installationID: row.installation_id,
      channelID: row.channel_id,
      appID: row.app_id,
      appName: row.app_name,
      eventType: row.event_type,
      instanceID: row.instance_id,
      oldState: row.old_state,
      newState: row.new_state,
      authoritativeTimestamp: row.authoritative_timestamp,
      receivedAt: row.received_at,
    };
    await claimAndQueue(event, env);
  }
}

/**
 * Atomically claims a durable outbox row before queueing. `enqueued = 2` is a
 * short-lived claim; stale claims and queue-consumer failures are recovered by
 * the scheduled handler. This prevents concurrent Apple redeliveries from
 * enqueueing the same event twice while retaining at-least-once delivery.
 */
async function claimAndQueue(event: QueuedEvent, env: Env): Promise<boolean> {
  const attemptedAt = new Date().toISOString();
  const claim = await env.DB.prepare(
    `UPDATE events SET enqueued = 2, enqueue_attempted_at = ?
     WHERE channel_id = ? AND event_id = ? AND (
       (enqueued = 0 AND (enqueue_attempted_at IS NULL OR julianday(enqueue_attempted_at) < julianday('now', '-5 minutes')))
       OR (enqueued = 2 AND julianday(enqueue_attempted_at) < julianday('now', '-5 minutes'))
     )`,
  ).bind(attemptedAt, event.channelID, event.eventID).run();
  if (claim.meta.changes !== 1) return false;
  try {
    await env.EVENTS_QUEUE.send(event);
    await env.DB.prepare(
      "UPDATE events SET enqueued = 1 WHERE channel_id = ? AND event_id = ?",
    ).bind(event.channelID, event.eventID).run();
    return true;
  } catch (error) {
    await env.DB.prepare(
      "UPDATE events SET enqueued = 0, enqueue_attempted_at = ? WHERE channel_id = ? AND event_id = ?",
    ).bind(new Date().toISOString(), event.channelID, event.eventID).run();
    throw error;
  }
}

function validateEventTypes(value: unknown): SupportedEventType[] {
  if (!Array.isArray(value) || value.length === 0) throw new HTTPError(400, "Select at least one webhook event type.");
  const unique = [...new Set(value)];
  if (!unique.every((item): item is SupportedEventType => typeof item === "string" && supportedEventTypes.includes(item as SupportedEventType))) {
    throw new HTTPError(400, "An unsupported webhook event type was requested.");
  }
  return unique;
}

async function bodyJSON<T>(request: Request, maximumBytes: number): Promise<T> {
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > maximumBytes) throw new HTTPError(413, "Request body is too large.");
  const raw = await request.arrayBuffer();
  if (raw.byteLength > maximumBytes) throw new HTTPError(413, "Request body is too large.");
  try {
    return JSON.parse(new TextDecoder().decode(raw)) as T;
  } catch {
    throw new HTTPError(400, "Request body must be valid JSON.");
  }
}

function validPublicBaseURL(value: string): string {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/") {
    throw new Error("PUBLIC_BASE_URL must be an HTTPS origin without credentials or a path");
  }
  return url.origin;
}

function inboundToConfiguredType(type: string): SupportedEventType | null {
  const mapping: Record<string, SupportedEventType> = {
    appStoreVersionAppVersionStateUpdated: "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED",
    buildUploadStateUpdated: "BUILD_UPLOAD_STATE_UPDATED",
    buildBetaDetailExternalBuildStateUpdated: "BUILD_BETA_DETAIL_EXTERNAL_BUILD_STATE_UPDATED",
    betaFeedbackCrashSubmissionCreated: "BETA_FEEDBACK_CRASH_SUBMISSION_CREATED",
    betaFeedbackScreenshotSubmissionCreated: "BETA_FEEDBACK_SCREENSHOT_SUBMISSION_CREATED",
  };
  return mapping[type] ?? null;
}

function validTimestamp(value: string): string | null {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? null : date.toISOString();
}

function safeStringArray(value: string): string[] {
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed) && parsed.every((item) => typeof item === "string") ? parsed : [];
  } catch {
    return [];
  }
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: jsonHeaders });
}

class HTTPError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

interface ApplePayload {
  data?: {
    id?: unknown;
    type?: unknown;
    version?: unknown;
    attributes?: Record<string, unknown>;
    relationships?: { instance?: { data?: { id?: unknown; type?: unknown } } };
  };
}

interface PendingEventRow {
  event_id: string;
  installation_id: string;
  channel_id: string;
  event_type: string;
  instance_id: string | null;
  old_state: string | null;
  new_state: string | null;
  authoritative_timestamp: string | null;
  received_at: string;
  app_id: string;
  app_name: string | null;
}

interface EventRow {
  event_id: string;
  installation_id: string;
  channel_id: string;
  event_type: string;
  instance_id: string | null;
  old_state: string | null;
  new_state: string | null;
  authoritative_timestamp: string | null;
  received_at: string;
  enqueued: number;
}
