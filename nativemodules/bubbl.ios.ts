import { NativeModules, NativeEventEmitter } from 'react-native';

const Bubbl =
  NativeModules.Bubbl ??
  NativeModules.BubblModule;

if (!Bubbl) {
  throw new Error(
    'Bubbl native module not found. ' +
      'Ensure BubblModule.swift/.m are compiled and linked in the iOS target for both legacy and New Architecture builds.',
  );
}

const emitter = new NativeEventEmitter(Bubbl);

export type BubblInitOptions = {
  environment?: 'STAGING' | 'PRODUCTION';
  segmentationTags?: string[];
  // Forwarded to iOS SDK polling override when that API is available.
  geoPollIntervalMs?: number;
  // Android-only; ignored by iOS bridge.
  defaultDistance?: number;
};

export type BubblSendEventParams = {
  curatedNotificationID: string;
  locationID: string;
  type: string;
  activity: string;
  latitude: number;
  longitude: number;
};

export type BubblGeofenceSnapshot = {
  stats: {
    campaignsTotal: number;
    polygonsTotal: number;
  };
  polygons: Array<{
    campaignId: number;
    campaignName: string;
    vertices: Array<{ latitude: number; longitude: number }>;
  }>;
  circles: Array<{
    campaignId: number;
    campaignName: string;
    center: { latitude: number; longitude: number };
    radius: number;
  }>;
};

export type BubblDeviceLogStreamOptions = {
  targetDeviceSuffix?: string;
  intervalMs?: number;
  maxLines?: number;
};

export type BubblDeviceLogInfo = {
  deviceType: 'android' | 'ios';
  deviceId: string;
  deviceIdSuffix: string;
};

export type BubblDeviceLogSnapshot = {
  deviceType: 'android' | 'ios';
  deviceId: string;
  deviceIdSuffix: string;
  timestamp: number;
  lines: string[];
};

export type BubblDeviceLogStartResult = {
  started: boolean;
  reason: string;
  deviceIdSuffix: string;
};

export const BubblBridge = {
  init: (apiKey: string, options: BubblInitOptions) =>
    Bubbl.init(apiKey, options),

  boot: (
    apiKey: string,
    env: 'STAGING' | 'PRODUCTION',
    options: BubblInitOptions = {},
  ) => Bubbl.boot(apiKey, env, options),

  requiredPermissions: async (): Promise<string[]> =>
    Bubbl.requiredPermissions(),
  locationGranted: async (): Promise<boolean> => Bubbl.locationGranted(),
  notificationGranted: async (): Promise<boolean> =>
    Bubbl.notificationGranted(),

  requestPushPermission: async (): Promise<boolean> =>
    Bubbl.requestPushPermission(),

  startLocationTracking: async (): Promise<boolean> =>
    Bubbl.startLocationTracking(),
  refreshGeofence: (lat: number, lng: number) =>
    Bubbl.refreshGeofence(lat, lng),

  updateSegments: async (segmentations: string[]): Promise<boolean> =>
    Bubbl.updateSegments(segmentations),

  setCorrelationId: async (correlationId: string): Promise<boolean> =>
    Bubbl.setCorrelationId(correlationId),
  getCorrelationId: async (): Promise<string> => Bubbl.getCorrelationId(),
  clearCorrelationId: async (): Promise<boolean> => Bubbl.clearCorrelationId(),

  getPrivacyText: async (): Promise<string> => Bubbl.getPrivacyText(),

  refreshPrivacyText: async (): Promise<string> => Bubbl.refreshPrivacyText(),

  getCurrentConfiguration: async (): Promise<{
    notificationsCount: number;
    daysCount: number;
    batteryCount: number;
    privacyText: string;
  } | null> => Bubbl.getCurrentConfiguration(),

  // Campaign state is derived from loaded geofence campaigns (polygons),
  // not from configuration.notificationsCount.
  hasCampaigns: async (): Promise<boolean> => Bubbl.hasCampaigns(),
  getCampaignCount: async (): Promise<number> => Bubbl.getCampaignCount(),
  forceRefreshCampaigns: async (): Promise<boolean> =>
    Bubbl.forceRefreshCampaigns(),
  clearCachedCampaigns: () => Bubbl.clearCachedCampaigns(),
  getDeviceLogStreamInfo: async (): Promise<BubblDeviceLogInfo> =>
    Bubbl.getDeviceLogStreamInfo(),
  getDeviceLogTail: async (maxLines: number = 80): Promise<string[]> =>
    Bubbl.getDeviceLogTail(maxLines),
  startDeviceLogStream: async (
    options: BubblDeviceLogStreamOptions = {},
  ): Promise<BubblDeviceLogStartResult> =>
    Bubbl.startDeviceLogStream(options),
  stopDeviceLogStream: (): void => Bubbl.stopDeviceLogStream(),

  getApiKey: async (): Promise<string> => Bubbl.getApiKey(),
  sayHello: async (): Promise<string> => Bubbl.sayHello(),
  sendEvent: async (params: BubblSendEventParams): Promise<boolean> =>
    Bubbl.sendEvent(
      params.curatedNotificationID,
      params.locationID,
      params.type,
      params.activity,
      params.latitude,
      params.longitude,
    ),

  cta: (notificationId: number, locationId: string) =>
    Bubbl.cta(notificationId, locationId),

  trackSurveyEvent: (
    notificationId: string,
    locationId: string,
    activity: string,
  ) => Bubbl.trackSurveyEvent(notificationId, locationId, activity),

  submitSurveyResponse: (
    notificationId: string,
    locationId: string,
    answers: any[],
  ) => Bubbl.submitSurveyResponse(notificationId, locationId, answers),

  startGeofenceUpdates: () => Bubbl.startGeofenceUpdates(),
  stopGeofenceUpdates: () => Bubbl.stopGeofenceUpdates(),
  onGeofence: (cb: (snap: BubblGeofenceSnapshot) => void) =>
    emitter.addListener('bubbl_geofence', cb),

  onNotification: (cb: (p: { raw: string }) => void) =>
    emitter.addListener('bubbl_notification', cb),
  onDeviceLog: (cb: (snapshot: BubblDeviceLogSnapshot) => void) =>
    emitter.addListener('bubbl_device_log', cb),

  testNotification: async (): Promise<boolean> => Bubbl.testNotification(),
};
