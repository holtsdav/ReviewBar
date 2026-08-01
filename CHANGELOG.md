# Changelog

## 0.1.1 — 2026-08-01

- Removed global iOS-only assumptions; added explicit iOS/iPadOS, macOS, tvOS, and visionOS presentation plus complete build pagination.
- Added official App Store and build-icon resolution with a validated bounded offline cache.
- Replaced per-app Releases/Builds tabs with a denser Overview and focused Release History/Builds destinations.
- Added official Analytics Reports import, gzip TSV parsing, report corrections, local instance caching, time ranges, charts, freshness, and actionable permission/generation states.
- Rebuilt Settings as compact native grouped sections.
- Added optional per-app App Store Connect webhook configuration and the isolated Cloudflare/APNs notification relay.
- Added authoritative webhook release timestamps, channel-scoped deduplication, outbox retry, feed pagination, APNs token recovery, retention cleanup, and privacy disclosures.
- Expanded platform, icon, Analytics, webhook, navigation, empty/error, accessibility, and relay regression coverage.

## 0.1.0

- Initial functional ReviewBar dashboard, authentication, releases, reviews, builds, caching, demo data, and automated test foundation.
