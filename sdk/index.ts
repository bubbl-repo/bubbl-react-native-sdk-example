export type {
  BubblInitOptions,
  BubblSendEventParams,
  BubblGeofenceSnapshot,
  BubblDeviceLogStreamOptions,
  BubblDeviceLogInfo,
  BubblDeviceLogSnapshot,
  BubblDeviceLogStartResult,
} from '../nativemodules/bubbl';
export { BubblBridge } from '../nativemodules/bubbl';

// Optional convenience types for consumers
export type BubblConfiguration = {
  notificationsCount: number;
  daysCount: number;
  batteryCount: number;
  privacyText: string;
};

export type BubblCampaignAvailability = {
  hasCampaigns: boolean;
  campaignCount: number;
  // Derived from loaded geofence campaigns/polygons, not configuration.notificationsCount.
  source: 'geofence_campaigns';
};

export type BubblNotificationPayload = {
  id?: number;
  headline?: string | null;
  body?: string | null;
  mediaUrl?: string | null;
  mediaType?: string | null;
  activation?: string | null;
  ctaLabel?: string | null;
  ctaUrl?: string | null;
  locationId?: string | null;
  postMessage?: string | null;
  source?: string | null;
  transport?: 'remote' | 'local' | 'unknown';
  isGeofenceRelated?: boolean;
  isRemoteGeofenceFallback?: boolean;
  questions?: Array<{
    id: number;
    question: string;
    question_type?: string | null;
    has_choices?: boolean;
    position?: number;
    choices?: Array<{
      id: number;
      choice: string;
      position?: number;
    }>;
  }> | null;
  raw?: string;
};
