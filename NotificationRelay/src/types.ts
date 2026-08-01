export const supportedEventTypes = [
  "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED",
  "BUILD_UPLOAD_STATE_UPDATED",
  "BUILD_BETA_DETAIL_EXTERNAL_BUILD_STATE_UPDATED",
  "BETA_FEEDBACK_CRASH_SUBMISSION_CREATED",
  "BETA_FEEDBACK_SCREENSHOT_SUBMISSION_CREATED",
] as const;

export type SupportedEventType = typeof supportedEventTypes[number];

export interface QueuedEvent {
  eventID: string;
  installationID: string;
  channelID: string;
  appID: string;
  appName: string | null;
  eventType: string;
  instanceID: string | null;
  oldState: string | null;
  newState: string | null;
  authoritativeTimestamp: string | null;
  receivedAt: string;
}

export interface InstallationRow {
  id: string;
  token_hash: string;
  apns_token_ciphertext: string;
  apns_environment: "sandbox" | "production";
  enabled: number;
}

export interface ChannelRow {
  id: string;
  installation_id: string;
  app_id: string;
  app_name: string | null;
  secret_ciphertext: string;
  apple_webhook_id: string | null;
  event_types_json: string;
  enabled: number;
}
