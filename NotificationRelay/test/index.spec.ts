import { env, SELF } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { dispatchQueuedEvent, notificationPayload, type APNSClient, type APNSResult } from "../src/apns";
import { appleSignature } from "../src/crypto";
import type { QueuedEvent } from "../src/types";
import worker from "../src/index";
import initialMigration from "../migrations/0001_initial.sql?raw";

declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {}
}

beforeAll(async () => {
  const statements = initialMigration.split(";").map((statement) => statement.trim()).filter(Boolean);
  await env.DB.batch(statements.map((statement) => env.DB.prepare(statement)));
});

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM events"),
    env.DB.prepare("DELETE FROM channels"),
    env.DB.prepare("DELETE FROM installations"),
  ]);
});

describe("Apple webhook relay", () => {
  it("accepts a valid signed app-version transition and exposes its authoritative timestamp", async () => {
    const setup = await createSetup();
    const body = JSON.stringify(versionEvent("event-1"));
    const response = await appleRequest(setup, body, await appleSignature(new TextEncoder().encode(body).buffer, setup.secret));
    expect(response.status).toBe(202);

    const feed = await SELF.fetch("https://relay.test.example/v1/events", {
      headers: { authorization: `Bearer ${setup.token}` },
    });
    const payload = await feed.json<{ events: Array<Record<string, unknown>> }>();
    expect(payload.events).toHaveLength(1);
    expect(payload.events[0].event_type).toBe("appStoreVersionAppVersionStateUpdated");
    expect(payload.events[0].new_state).toBe("IN_REVIEW");
    expect(payload.events[0].authoritative_timestamp).toBe("2026-08-01T01:02:03.000Z");
  });

  it("rejects an invalid HMAC before parsing", async () => {
    const setup = await createSetup();
    const response = await appleRequest(setup, "not json", `hmacsha256=${"0".repeat(64)}`);
    expect(response.status).toBe(401);
  });

  it("atomically deduplicates concurrent Apple redelivery by event ID", async () => {
    const setup = await createSetup();
    const body = JSON.stringify(versionEvent("same-event"));
    const signature = await appleSignature(new TextEncoder().encode(body).buffer, setup.secret);
    const [first, second] = await Promise.all([
      appleRequest(setup, body, signature),
      appleRequest(setup, body, signature),
    ]);
    expect(first.status).toBe(202);
    expect(second.status).toBe(202);
    const duplicateFlags = await Promise.all([first.clone(), second.clone()].map(async (response) =>
      (await response.json<{ duplicate: boolean }>()).duplicate));
    expect(duplicateFlags.sort()).toEqual([false, true]);
    const count = await env.DB.prepare("SELECT COUNT(*) AS count, MAX(enqueued) AS enqueued FROM events")
      .first<{ count: number; enqueued: number }>();
    expect(count?.count).toBe(1);
    expect(count?.enqueued).toBe(1);
  });

  it("rejects malformed JSON after a valid signature", async () => {
    const setup = await createSetup();
    const body = "{bad";
    const signature = await appleSignature(new TextEncoder().encode(body).buffer, setup.secret);
    expect((await appleRequest(setup, body, signature)).status).toBe(400);
  });

  it("rejects a known transition with missing required schema", async () => {
    const setup = await createSetup();
    const malformed = versionEvent("missing-timestamp") as { data: { attributes: Record<string, unknown> } };
    delete malformed.data.attributes.timestamp;
    const body = JSON.stringify(malformed);
    const signature = await appleSignature(new TextEncoder().encode(body).buffer, setup.secret);
    expect((await appleRequest(setup, body, signature)).status).toBe(400);
  });

  it("acknowledges signed ping or future envelopes without storing or alerting", async () => {
    const setup = await createSetup();
    const body = JSON.stringify({ data: { type: "webhookPing", id: "ping-1", version: 1 } });
    const signature = await appleSignature(new TextEncoder().encode(body).buffer, setup.secret);
    const response = await appleRequest(setup, body, signature);
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({ ignored: true });
    const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM events").first<{ count: number }>();
    expect(count?.count).toBe(0);
  });

  it("deduplicates within a channel rather than suppressing another installation", async () => {
    const first = await createSetup();
    const second = await createSetup();
    for (const setup of [first, second]) {
      const body = JSON.stringify(versionEvent("shared-apple-event"));
      const signature = await appleSignature(new TextEncoder().encode(body).buffer, setup.secret);
      expect((await appleRequest(setup, body, signature)).status).toBe(202);
    }
    const count = await env.DB.prepare("SELECT COUNT(*) AS count FROM events WHERE event_id = ?")
      .bind("shared-apple-event").first<{ count: number }>();
    expect(count?.count).toBe(2);
  });

  it("paginates more than 100 retained events oldest first without skipping", async () => {
    const setup = await createSetup();
    const statements = Array.from({ length: 101 }, (_, index) => env.DB.prepare(
      "INSERT INTO events (event_id, installation_id, channel_id, event_type, new_state, received_at, enqueued) VALUES (?, ?, ?, ?, ?, ?, 1)",
    ).bind(
      `bulk-${index.toString().padStart(3, "0")}`,
      setup.installationID,
      setup.channelID,
      "buildUploadStateUpdated",
      "COMPLETE",
      new Date(Date.UTC(2026, 7, 1, 0, 0, index)).toISOString(),
    ));
    for (let index = 0; index < statements.length; index += 40) {
      await env.DB.batch(statements.slice(index, index + 40));
    }

    const firstResponse = await SELF.fetch("https://relay.test.example/v1/events", {
      headers: { authorization: `Bearer ${setup.token}` },
    });
    const first = await firstResponse.json<{ events: Array<{ event_id: string }>; nextCursor: string | null }>();
    expect(first.events).toHaveLength(100);
    expect(first.events[0].event_id).toBe("bulk-000");
    expect(first.nextCursor).toBeTypeOf("string");

    const secondResponse = await SELF.fetch(`https://relay.test.example/v1/events?cursor=${encodeURIComponent(first.nextCursor!)}`, {
      headers: { authorization: `Bearer ${setup.token}` },
    });
    const second = await secondResponse.json<{
      events: Array<{ event_id: string }>;
      nextCursor: string | null;
      checkpointCursor: string | null;
    }>();
    expect(second.events.map((event) => event.event_id)).toEqual(["bulk-100"]);
    expect(second.nextCursor).toBeNull();
    expect(second.checkpointCursor).toBeTypeOf("string");
  });

  it("accepts build upload events without inventing a timestamp or build number", async () => {
    const setup = await createSetup();
    const body = JSON.stringify({
      data: {
        type: "buildUploadStateUpdated",
        id: "build-event",
        version: 1,
        attributes: { newState: "COMPLETE" },
        relationships: { instance: { data: { type: "buildUploads", id: "upload-id" } } },
      },
    });
    const signature = await appleSignature(new TextEncoder().encode(body).buffer, setup.secret);
    expect((await appleRequest(setup, body, signature)).status).toBe(202);
    const event = await env.DB.prepare("SELECT * FROM events WHERE event_id = ?").bind("build-event").first<Record<string, unknown>>();
    expect(event?.new_state).toBe("COMPLETE");
    expect(event?.authoritative_timestamp).toBeNull();
  });

  it("scheduled retention removes expired events and abandoned unconfirmed enrollment", async () => {
    const active = await createSetup();
    const old = new Date(Date.now() - 31 * 86_400_000).toISOString();
    const recent = new Date(Date.now() - 29 * 86_400_000).toISOString();
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO events (event_id, installation_id, channel_id, event_type, received_at, enqueued) VALUES (?, ?, ?, ?, ?, 1)",
      ).bind("expired-event", active.installationID, active.channelID, "buildUploadStateUpdated", old),
      env.DB.prepare(
        "INSERT INTO events (event_id, installation_id, channel_id, event_type, received_at, enqueued) VALUES (?, ?, ?, ?, ?, 1)",
      ).bind("retained-event", active.installationID, active.channelID, "buildUploadStateUpdated", recent),
    ]);

    const abandoned = await createSetup();
    await env.DB.prepare("UPDATE channels SET created_at = ? WHERE id = ?")
      .bind(new Date(Date.now() - 25 * 3_600_000).toISOString(), abandoned.channelID).run();
    await env.DB.prepare("UPDATE installations SET created_at = ? WHERE id = ?")
      .bind(new Date(Date.now() - 25 * 3_600_000).toISOString(), abandoned.installationID).run();

    await worker.scheduled({} as ScheduledController, env);
    expect(await env.DB.prepare("SELECT event_id FROM events ORDER BY event_id").all<{ event_id: string }>())
      .toMatchObject({ results: [{ event_id: "retained-event" }] });
    expect(await env.DB.prepare("SELECT id FROM installations WHERE id = ?").bind(abandoned.installationID).first())
      .toBeNull();
  });
});

describe("APNs dispatch abstraction", () => {
  it("builds a state-specific notification and dispatches without exposing credentials", async () => {
    const setup = await createSetup();
    const event: QueuedEvent = {
      eventID: "notification-event",
      installationID: setup.installationID,
      channelID: setup.channelID,
      appID: "123",
      appName: "Glassdays",
      eventType: "appStoreVersionAppVersionStateUpdated",
      instanceID: "version-id",
      oldState: "WAITING_FOR_REVIEW",
      newState: "IN_REVIEW",
      authoritativeTimestamp: "2026-08-01T01:02:03.000Z",
      receivedAt: "2026-08-01T01:02:04.000Z",
    };
    const client = new CapturingAPNSClient();
    await dispatchQueuedEvent(event, env, client);
    expect(client.tokens).toEqual(["a".repeat(64)]);
    expect(notificationPayload(event)).toMatchObject({
      aps: { alert: { title: "Glassdays entered App Review" } },
    });
  });

  it("disables ingestion after a permanent token failure and permits token recovery", async () => {
    const setup = await createSetup();
    const event: QueuedEvent = {
      eventID: "bad-token-event",
      installationID: setup.installationID,
      channelID: setup.channelID,
      appID: "123",
      appName: "Glassdays",
      eventType: "buildUploadStateUpdated",
      instanceID: "upload-id",
      oldState: null,
      newState: "COMPLETE",
      authoritativeTimestamp: null,
      receivedAt: "2026-08-01T01:02:04.000Z",
    };
    await dispatchQueuedEvent(event, env, new PermanentFailureAPNSClient());
    expect((await env.DB.prepare("SELECT enabled FROM channels WHERE id = ?").bind(setup.channelID).first<{ enabled: number }>())?.enabled).toBe(0);

    const recovery = await SELF.fetch("https://relay.test.example/v1/installations/current/device-token", {
      method: "PATCH",
      headers: { "content-type": "application/json", authorization: `Bearer ${setup.token}` },
      body: JSON.stringify({ apnsToken: "b".repeat(64), apnsEnvironment: "sandbox" }),
    });
    expect(recovery.status).toBe(200);
    expect((await env.DB.prepare("SELECT enabled FROM channels WHERE id = ?").bind(setup.channelID).first<{ enabled: number }>())?.enabled).toBe(1);
  });
});

async function createSetup(): Promise<{
  installationID: string;
  token: string;
  channelID: string;
  secret: string;
  webhookURL: string;
}> {
  const registration = await SELF.fetch("https://relay.test.example/v1/installations", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ apnsToken: "a".repeat(64), apnsEnvironment: "sandbox" }),
  });
  expect(registration.status).toBe(201);
  const installed = await registration.json<{ installationID: string; token: string }>();
  const channel = await SELF.fetch("https://relay.test.example/v1/channels", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${installed.token}` },
    body: JSON.stringify({
      appID: "123",
      appName: "Glassdays",
      eventTypes: [
        "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED",
        "BUILD_UPLOAD_STATE_UPDATED",
        "BUILD_BETA_DETAIL_EXTERNAL_BUILD_STATE_UPDATED",
      ],
    }),
  });
  expect(channel.status).toBe(201);
  return { ...installed, ...await channel.json<{ channelID: string; secret: string; webhookURL: string }>() };
}

function versionEvent(id: string): object {
  return {
    data: {
      type: "appStoreVersionAppVersionStateUpdated",
      id,
      version: 1,
      attributes: {
        newValue: "IN_REVIEW",
        oldValue: "WAITING_FOR_REVIEW",
        timestamp: "2026-08-01T01:02:03Z",
      },
      relationships: { instance: { data: { type: "appStoreVersions", id: "version-id" } } },
    },
  };
}

async function appleRequest(
  setup: { webhookURL: string },
  body: string,
  signature: string,
): Promise<Response> {
  return SELF.fetch(setup.webhookURL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-apple-signature": signature },
    body,
  });
}

class CapturingAPNSClient implements APNSClient {
  readonly tokens: string[] = [];
  async send(token: string): Promise<APNSResult> {
    this.tokens.push(token);
    return { status: 200 };
  }
}

class PermanentFailureAPNSClient implements APNSClient {
  async send(): Promise<APNSResult> {
    return { status: 410, reason: "Unregistered" };
  }
}
