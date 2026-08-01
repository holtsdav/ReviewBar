interface Env {
  DB: D1Database;
  EVENTS_QUEUE: Queue<import("./types").QueuedEvent>;
  PUBLIC_BASE_URL: string;
  APNS_TOPIC: string;
  RELAY_ENCRYPTION_KEY: string;
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
}

declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    EVENTS_QUEUE: Queue<import("./types").QueuedEvent>;
    PUBLIC_BASE_URL: string;
    APNS_TOPIC: string;
    RELAY_ENCRYPTION_KEY: string;
    APNS_KEY_P8: string;
    APNS_KEY_ID: string;
    APNS_TEAM_ID: string;
  }
}
