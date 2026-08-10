# Changelog

## Unreleased

- Added locally persisted favorite apps, favorite-first sorting, portfolio totals, and a needs-attention workflow for failed releases/builds and section issues.
- Added full-text review search, unread and developer-response filters, rating/response coverage, and native review sharing.
- Added build-number/version search, an explicit app-list refresh action, refresh recency, and clearer empty-state recovery.
- Updated the tab bar to the modern typed API and improved app-switcher, destructive-action, cache-progress, and lifecycle-refresh accessibility/behavior.
- Simplified Analytics report importing so its documented sequential memory behavior no longer creates redundant one-child task groups.
- Added preference, attention, and review-workflow regression coverage plus a complete app/relay audit record.

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
