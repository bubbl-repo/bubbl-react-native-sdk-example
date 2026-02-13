import { Platform } from 'react-native';

export type {
  BubblInitOptions,
  BubblSendEventParams,
  BubblGeofenceSnapshot,
  BubblDeviceLogStreamOptions,
  BubblDeviceLogInfo,
  BubblDeviceLogSnapshot,
  BubblDeviceLogStartResult,
} from './bubbl.android';

// Platform-select the native bridge to avoid masking .ios/.android files.
const moduleImpl =
  Platform.OS === 'ios'
    ? require('./bubbl.ios')
    : require('./bubbl.android');

export const BubblBridge = moduleImpl.BubblBridge;
