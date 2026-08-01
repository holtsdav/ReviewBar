# ReviewBar Notification Relay

This isolated Cloudflare Worker is the smallest server-side component needed for optional App Store Connect webhook notifications. It receives Apple-signed webhook requests, deduplicates event IDs per channel in D1, queues normalized events through a recoverable outbox, and sends ReviewBar alerts through APNs.

It never receives or stores a user's App Store Connect private key, issuer ID, or JWT. The iPhone creates and deletes Apple webhook configurations directly with its on-device Keychain credential. D1 stores only opaque installation/channel identifiers, a hash of the relay bearer token, AES-GCM-encrypted APNs and webhook secrets, app metadata needed for alerts, preferences, and normalized recent events. Raw Apple payloads and signed download URLs are not retained or logged.

The iPhone persists a provisional cleanup mapping before it creates/confirms an Apple webhook. If setup or compensation loses connectivity, the channel ID, optional Apple webhook ID, and bearer remain recoverable in Keychain and cleanup is retried rather than orphaning a server resource.

## Deployment

1. Install dependencies with `npm install` and run `npm test && npm run check`.
2. Create D1 and queues:
   - `npx wrangler d1 create reviewbar-relay`
   - `npx wrangler queues create reviewbar-webhook-events`
   - `npx wrangler queues create reviewbar-webhook-events-dlq`
3. Replace the D1 ID and `PUBLIC_BASE_URL` in `wrangler.jsonc`.
4. Create secrets using `npx wrangler secret put` for:
   - `RELAY_ENCRYPTION_KEY` (at least 32 random characters)
   - `APNS_KEY_P8` (ReviewBar's APNs `.p8`, not a user's App Store Connect key)
   - `APNS_KEY_ID`
   - `APNS_TEAM_ID`
5. Apply D1 migrations with `npx wrangler d1 migrations apply reviewbar-relay --remote`.
6. Deploy with `npm run deploy`, then set the iOS build setting `REVIEWBAR_RELAY_BASE_URL` to the resulting HTTPS origin and enable the push-notification capability.

7. On the Cloudflare zone, enable **Always Use HTTPS**, HSTS, and WAF rate limits for `/v1/installations` and `/apple/*`. The Worker independently rejects non-HTTPS requests and emits HSTS; the zone controls ensure clients never reach an HTTP origin first.

Use a dedicated APNs key and rotate `RELAY_ENCRYPTION_KEY` only with a migration that re-encrypts stored values. The current minimal enrollment endpoint accepts only structurally valid ReviewBar APNs tokens and returns an installation-scoped random bearer token; App Attest is the recommended next hardening layer for high-volume public deployment.

The hourly scheduled job retries pending or stale-claimed outbox rows and removes normalized events after the 30-day cutoff. It also removes never-confirmed channels and empty installations once they are 24 hours old, bounding retention if a device cannot persist its first bearer. Keep the cron trigger enabled. Queue-consumer failures return the durable D1 row to pending, so delivery can recover after ordinary retries or DLQ exhaustion. APNs provider tokens are reused for 50 minutes, within Apple’s one-hour lifetime and refresh guidance.

`0001_initial.sql` is the baseline for a new, not-yet-deployed relay. If an earlier local relay schema was applied, recreate the development database or add an explicit forward migration before deployment; do not edit a migration after production use.

## Apple behavior

- Signature: `x-apple-signature: hmacsha256=<hex>` over the exact raw body.
- Redelivery uses the same event ID; D1 `INSERT OR IGNORE` plus an atomic outbox claim provides channel-scoped idempotency before queue dispatch.
- Dedupe scope is `(channel_id, event_id)`, so the same Apple event delivered through two users’ webhooks cannot suppress either installation.
- Exact transition timestamps are stored only when Apple supplies `attributes.timestamp`.
- `BUILD_UPLOAD_STATE_UPDATED` has no documented timestamp or build number, so the relay does not invent either.
- Known event types must match Apple’s type-specific required schema. Signed ping/future envelopes receive a successful no-op response and never produce a generic notification.
- The device event feed is cursor-paginated oldest-first and returns an opaque `(received_at, event_id, channel_id)` checkpoint. The iPhone persists that exact cursor, so same-timestamp events and bursts larger than 100 cannot skip release transitions.
- Apple currently has no customer App Store review-created webhook.
