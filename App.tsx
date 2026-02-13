import React, {useEffect, useMemo, useState} from 'react';
import {
  PermissionsAndroid,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';

import {BubblBridge} from './sdk';

type Environment = 'STAGING' | 'PRODUCTION';

type LogSubscription = {
  remove?: () => void;
};

const environmentOptions: Environment[] = ['STAGING', 'PRODUCTION'];

function stringifyValue(value: unknown): string {
  if (typeof value === 'string') {
    return value;
  }

  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function nowLabel(): string {
  return new Date().toLocaleTimeString();
}

function ActionButton({
  label,
  onPress,
}: {
  label: string;
  onPress: () => void;
}): React.JSX.Element {
  return (
    <TouchableOpacity onPress={onPress} style={styles.button}>
      <Text style={styles.buttonText}>{label}</Text>
    </TouchableOpacity>
  );
}

export default function App(): React.JSX.Element {
  const [apiKey, setApiKey] = useState('REPLACE_WITH_API_KEY');
  const [environment, setEnvironment] = useState<Environment>('STAGING');
  const [segmentsInput, setSegmentsInput] = useState('vip,early_access');
  const [latitude, setLatitude] = useState('6.5244');
  const [longitude, setLongitude] = useState('3.3792');
  const [correlationId, setCorrelationId] = useState('demo-user-123');
  const [notificationId, setNotificationId] = useState('101');
  const [locationId, setLocationId] = useState('demo-location-1');
  const [logs, setLogs] = useState<string[]>([]);

  const parsedNotificationId = useMemo(() => {
    const numeric = Number(notificationId.trim());
    if (Number.isNaN(numeric)) {
      return 0;
    }
    return numeric;
  }, [notificationId]);

  const parsedLat = useMemo(() => {
    const numeric = Number(latitude.trim());
    return Number.isNaN(numeric) ? 0 : numeric;
  }, [latitude]);

  const parsedLng = useMemo(() => {
    const numeric = Number(longitude.trim());
    return Number.isNaN(numeric) ? 0 : numeric;
  }, [longitude]);

  const appendLog = (line: string) => {
    setLogs(previous => [`${nowLabel()} ${line}`, ...previous].slice(0, 120));
  };

  const runAction = async (name: string, fn: () => Promise<unknown> | unknown) => {
    try {
      const result = await fn();
      appendLog(`${name}: ${stringifyValue(result)}`);
    } catch (error) {
      appendLog(`${name} failed: ${stringifyValue(error)}`);
    }
  };

  const segments = useMemo(
    () =>
      segmentsInput
        .split(',')
        .map(entry => entry.trim())
        .filter(Boolean),
    [segmentsInput],
  );

  useEffect(() => {
    const notificationSub: LogSubscription = BubblBridge.onNotification((payload: any) => {
      appendLog(`event:onNotification => ${stringifyValue(payload)}`);
    }) as LogSubscription;

    const geofenceSub: LogSubscription = BubblBridge.onGeofence((snapshot: any) => {
      appendLog(`event:onGeofence => ${stringifyValue(snapshot)}`);
    }) as LogSubscription;

    const deviceLogSub: LogSubscription = BubblBridge.onDeviceLog((snapshot: any) => {
      appendLog(`event:onDeviceLog => ${stringifyValue(snapshot)}`);
    }) as LogSubscription;

    return () => {
      notificationSub?.remove?.();
      geofenceSub?.remove?.();
      deviceLogSub?.remove?.();
      BubblBridge.stopGeofenceUpdates();
      BubblBridge.stopDeviceLogStream();
    };
  }, []);

  const requestAndroidPermissions = async () => {
    if (Platform.OS !== 'android') {
      return [];
    }

    const permissions = await BubblBridge.requiredPermissions();
    if (!permissions.length) {
      return [];
    }

    const result = await PermissionsAndroid.requestMultiple(permissions as any);
    return result;
  };

  const sampleAnswers = [
    {
      question_id: 1,
      type: 'RATING',
      value: '5',
    },
    {
      question_id: 2,
      type: 'MULTIPLE_CHOICE',
      value: 'YES',
      choice: [{choice_id: 10}],
    },
  ];

  return (
    <View style={styles.safeArea}>
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.title}>Bubbl RN SDK Example</Text>
        <Text style={styles.subtitle}>Method playground aligned with guides/react-native-sdk/method-reference.md</Text>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Setup</Text>
          <TextInput
            style={styles.input}
            value={apiKey}
            onChangeText={setApiKey}
            autoCapitalize="none"
            placeholder="Bubbl API key"
          />
          <View style={styles.row}>
            {environmentOptions.map(value => (
              <TouchableOpacity
                key={value}
                onPress={() => setEnvironment(value)}
                style={[
                  styles.chip,
                  environment === value ? styles.chipActive : null,
                ]}>
                <Text
                  style={[
                    styles.chipText,
                    environment === value ? styles.chipTextActive : null,
                  ]}>
                  {value}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
          <ActionButton
            label="init(apiKey, options)"
            onPress={() =>
              void runAction('init', () =>
                BubblBridge.init(apiKey, {
                  environment,
                  segmentationTags: segments,
                  geoPollIntervalMs: 300000,
                  defaultDistance: 25,
                }),
              )
            }
          />
          <ActionButton
            label="boot(apiKey, env, options)"
            onPress={() =>
              void runAction('boot', () =>
                BubblBridge.boot(apiKey, environment, {
                  segmentationTags: segments,
                  geoPollIntervalMs: 300000,
                  defaultDistance: 25,
                }),
              )
            }
          />
          <ActionButton
            label="requiredPermissions()"
            onPress={() => void runAction('requiredPermissions', () => BubblBridge.requiredPermissions())}
          />
          <ActionButton
            label="request Android permissions"
            onPress={() => void runAction('PermissionsAndroid.requestMultiple', requestAndroidPermissions)}
          />
          <ActionButton
            label="locationGranted()"
            onPress={() => void runAction('locationGranted', () => BubblBridge.locationGranted())}
          />
          <ActionButton
            label="notificationGranted()"
            onPress={() => void runAction('notificationGranted', () => BubblBridge.notificationGranted())}
          />
          <ActionButton
            label="requestPushPermission()"
            onPress={() => void runAction('requestPushPermission', () => BubblBridge.requestPushPermission())}
          />
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Location and Campaigns</Text>
          <View style={styles.row}>
            <TextInput
              style={[styles.input, styles.halfInput]}
              value={latitude}
              onChangeText={setLatitude}
              keyboardType="decimal-pad"
              placeholder="Latitude"
            />
            <TextInput
              style={[styles.input, styles.halfInput]}
              value={longitude}
              onChangeText={setLongitude}
              keyboardType="decimal-pad"
              placeholder="Longitude"
            />
          </View>
          <ActionButton
            label="startLocationTracking()"
            onPress={() => void runAction('startLocationTracking', () => BubblBridge.startLocationTracking())}
          />
          <ActionButton
            label="refreshGeofence(lat, lng)"
            onPress={() =>
              void runAction('refreshGeofence', () => {
                BubblBridge.refreshGeofence(parsedLat, parsedLng);
                return Promise.resolve(true);
              })
            }
          />
          <ActionButton
            label="startGeofenceUpdates()"
            onPress={() =>
              void runAction('startGeofenceUpdates', () => {
                BubblBridge.startGeofenceUpdates();
                return Promise.resolve(true);
              })
            }
          />
          <ActionButton
            label="stopGeofenceUpdates()"
            onPress={() =>
              void runAction('stopGeofenceUpdates', () => {
                BubblBridge.stopGeofenceUpdates();
                return Promise.resolve(true);
              })
            }
          />
          <ActionButton
            label="hasCampaigns()"
            onPress={() => void runAction('hasCampaigns', () => BubblBridge.hasCampaigns())}
          />
          <ActionButton
            label="getCampaignCount()"
            onPress={() => void runAction('getCampaignCount', () => BubblBridge.getCampaignCount())}
          />
          <ActionButton
            label="forceRefreshCampaigns()"
            onPress={() => void runAction('forceRefreshCampaigns', () => BubblBridge.forceRefreshCampaigns())}
          />
          <ActionButton
            label="clearCachedCampaigns()"
            onPress={() =>
              void runAction('clearCachedCampaigns', () => {
                BubblBridge.clearCachedCampaigns();
                return Promise.resolve(true);
              })
            }
          />
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Segmentation and Configuration</Text>
          <TextInput
            style={styles.input}
            value={segmentsInput}
            onChangeText={setSegmentsInput}
            autoCapitalize="none"
            placeholder="segments (comma separated)"
          />
          <TextInput
            style={styles.input}
            value={correlationId}
            onChangeText={setCorrelationId}
            autoCapitalize="none"
            placeholder="correlation id"
          />
          <ActionButton
            label="updateSegments(tags)"
            onPress={() => void runAction('updateSegments', () => BubblBridge.updateSegments(segments))}
          />
          <ActionButton
            label="setCorrelationId(id)"
            onPress={() =>
              void runAction('setCorrelationId', () => BubblBridge.setCorrelationId(correlationId.trim()))
            }
          />
          <ActionButton
            label="getCorrelationId()"
            onPress={() => void runAction('getCorrelationId', () => BubblBridge.getCorrelationId())}
          />
          <ActionButton
            label="clearCorrelationId()"
            onPress={() => void runAction('clearCorrelationId', () => BubblBridge.clearCorrelationId())}
          />
          <ActionButton
            label="getCurrentConfiguration()"
            onPress={() => void runAction('getCurrentConfiguration', () => BubblBridge.getCurrentConfiguration())}
          />
          <ActionButton
            label="getPrivacyText()"
            onPress={() => void runAction('getPrivacyText', () => BubblBridge.getPrivacyText())}
          />
          <ActionButton
            label="refreshPrivacyText()"
            onPress={() => void runAction('refreshPrivacyText', () => BubblBridge.refreshPrivacyText())}
          />
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Events, Surveys, and Diagnostics</Text>
          <TextInput
            style={styles.input}
            value={notificationId}
            onChangeText={setNotificationId}
            keyboardType="number-pad"
            placeholder="notification id"
          />
          <TextInput
            style={styles.input}
            value={locationId}
            onChangeText={setLocationId}
            autoCapitalize="none"
            placeholder="location id"
          />
          <ActionButton
            label="sendEvent(params)"
            onPress={() =>
              void runAction('sendEvent', () =>
                BubblBridge.sendEvent({
                  curatedNotificationID: notificationId.trim() || '1',
                  locationID: locationId.trim() || 'demo-location-1',
                  type: 'notification',
                  activity: 'notification_delivered',
                  latitude: parsedLat,
                  longitude: parsedLng,
                }),
              )
            }
          />
          <ActionButton
            label="cta(notificationId, locationId)"
            onPress={() =>
              void runAction('cta', () => {
                BubblBridge.cta(parsedNotificationId, locationId.trim() || 'demo-location-1');
                return Promise.resolve(true);
              })
            }
          />
          <ActionButton
            label="trackSurveyEvent(notificationId, locationId, activity)"
            onPress={() =>
              void runAction('trackSurveyEvent', () =>
                BubblBridge.trackSurveyEvent(
                  notificationId.trim() || '1',
                  locationId.trim() || 'demo-location-1',
                  'notification_opened',
                ),
              )
            }
          />
          <ActionButton
            label="submitSurveyResponse(notificationId, locationId, answers)"
            onPress={() =>
              void runAction('submitSurveyResponse', () =>
                BubblBridge.submitSurveyResponse(
                  notificationId.trim() || '1',
                  locationId.trim() || 'demo-location-1',
                  sampleAnswers,
                ),
              )
            }
          />
          <ActionButton
            label="getApiKey()"
            onPress={() => void runAction('getApiKey', () => BubblBridge.getApiKey())}
          />
          <ActionButton
            label="sayHello()"
            onPress={() => void runAction('sayHello', () => BubblBridge.sayHello())}
          />
          <ActionButton
            label="getDeviceLogStreamInfo()"
            onPress={() =>
              void runAction('getDeviceLogStreamInfo', () => BubblBridge.getDeviceLogStreamInfo())
            }
          />
          <ActionButton
            label="getDeviceLogTail(maxLines)"
            onPress={() => void runAction('getDeviceLogTail', () => BubblBridge.getDeviceLogTail(40))}
          />
          <ActionButton
            label="startDeviceLogStream(options)"
            onPress={() =>
              void runAction('startDeviceLogStream', () =>
                BubblBridge.startDeviceLogStream({
                  intervalMs: 2500,
                  maxLines: 40,
                }),
              )
            }
          />
          <ActionButton
            label="stopDeviceLogStream()"
            onPress={() =>
              void runAction('stopDeviceLogStream', () => {
                BubblBridge.stopDeviceLogStream();
                return Promise.resolve(true);
              })
            }
          />
          <ActionButton
            label="testNotification()"
            onPress={() => void runAction('testNotification', () => BubblBridge.testNotification())}
          />
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Log</Text>
          {logs.length === 0 ? (
            <Text style={styles.logLine}>No actions yet.</Text>
          ) : (
            logs.map((line, index) => (
              <Text key={`${line}-${index}`} style={styles.logLine}>
                {line}
              </Text>
            ))
          )}
        </View>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#0b1220',
  },
  container: {
    padding: 16,
    gap: 16,
  },
  title: {
    fontSize: 22,
    fontWeight: '700',
    color: '#f8fafc',
  },
  subtitle: {
    fontSize: 12,
    color: '#94a3b8',
  },
  card: {
    borderWidth: 1,
    borderColor: '#1f2937',
    borderRadius: 12,
    backgroundColor: '#111827',
    padding: 12,
    gap: 8,
  },
  cardTitle: {
    color: '#e2e8f0',
    fontWeight: '600',
    marginBottom: 4,
  },
  row: {
    flexDirection: 'row',
    gap: 8,
  },
  input: {
    borderWidth: 1,
    borderColor: '#334155',
    borderRadius: 8,
    paddingHorizontal: 10,
    paddingVertical: 8,
    color: '#f8fafc',
    backgroundColor: '#0f172a',
    marginBottom: 4,
  },
  halfInput: {
    flex: 1,
  },
  chip: {
    borderWidth: 1,
    borderColor: '#334155',
    borderRadius: 16,
    paddingVertical: 6,
    paddingHorizontal: 10,
  },
  chipActive: {
    borderColor: '#38bdf8',
    backgroundColor: '#0c4a6e',
  },
  chipText: {
    color: '#cbd5e1',
    fontSize: 12,
  },
  chipTextActive: {
    color: '#e0f2fe',
    fontWeight: '600',
  },
  button: {
    backgroundColor: '#1d4ed8',
    paddingVertical: 10,
    paddingHorizontal: 12,
    borderRadius: 8,
  },
  buttonText: {
    color: '#eff6ff',
    fontSize: 13,
    fontWeight: '600',
  },
  logLine: {
    color: '#cbd5e1',
    fontSize: 12,
    marginBottom: 4,
  },
});
