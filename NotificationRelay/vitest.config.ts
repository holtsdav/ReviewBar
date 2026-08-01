import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        PUBLIC_BASE_URL: "https://relay.test.example",
        APNS_TOPIC: "com.reviewbar.ReviewBar",
        RELAY_ENCRYPTION_KEY: "test-only-encryption-key-at-least-32-characters",
        APNS_KEY_P8: "test-key-not-used",
        APNS_KEY_ID: "TESTKEY",
        APNS_TEAM_ID: "TESTTEAM",
      },
    },
  })],
  test: {
    isolate: true,
  },
});
