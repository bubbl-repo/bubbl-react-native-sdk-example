/**
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';

jest.mock('../sdk', () => ({
  BubblBridge: {
    init: jest.fn(() => Promise.resolve({initializedNow: true})),
    boot: jest.fn(() => Promise.resolve({initializedNow: true})),
    requiredPermissions: jest.fn(() => Promise.resolve([])),
    locationGranted: jest.fn(() => Promise.resolve(true)),
    notificationGranted: jest.fn(() => Promise.resolve(true)),
    requestPushPermission: jest.fn(() => Promise.resolve(true)),
    startLocationTracking: jest.fn(() => Promise.resolve(true)),
    refreshGeofence: jest.fn(),
    startGeofenceUpdates: jest.fn(),
    stopGeofenceUpdates: jest.fn(),
    hasCampaigns: jest.fn(() => Promise.resolve(false)),
    getCampaignCount: jest.fn(() => Promise.resolve(0)),
    forceRefreshCampaigns: jest.fn(() => Promise.resolve(true)),
    clearCachedCampaigns: jest.fn(),
    updateSegments: jest.fn(() => Promise.resolve(true)),
    setCorrelationId: jest.fn(() => Promise.resolve(true)),
    getCorrelationId: jest.fn(() => Promise.resolve('demo-user-123')),
    clearCorrelationId: jest.fn(() => Promise.resolve(true)),
    getCurrentConfiguration: jest.fn(() => Promise.resolve(null)),
    getPrivacyText: jest.fn(() => Promise.resolve('privacy')),
    refreshPrivacyText: jest.fn(() => Promise.resolve('privacy')),
    sendEvent: jest.fn(() => Promise.resolve(true)),
    cta: jest.fn(),
    trackSurveyEvent: jest.fn(() => Promise.resolve(true)),
    submitSurveyResponse: jest.fn(() => Promise.resolve(true)),
    getApiKey: jest.fn(() => Promise.resolve('REPLACE_WITH_API_KEY')),
    sayHello: jest.fn(() => Promise.resolve('hello')),
    getDeviceLogStreamInfo: jest.fn(() => Promise.resolve({deviceId: 'd1'})),
    getDeviceLogTail: jest.fn(() => Promise.resolve([])),
    startDeviceLogStream: jest.fn(() => Promise.resolve({started: true})),
    stopDeviceLogStream: jest.fn(),
    testNotification: jest.fn(() => Promise.resolve(true)),
    onNotification: jest.fn(() => ({remove: jest.fn()})),
    onGeofence: jest.fn(() => ({remove: jest.fn()})),
    onDeviceLog: jest.fn(() => ({remove: jest.fn()})),
  },
}));

import App from '../App';

test('renders playground shell', async () => {
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });

  const treeText = JSON.stringify(renderer?.toJSON());
  expect(treeText).toContain('Bubbl RN SDK Example');
  expect(treeText).toContain('Method playground aligned with guides/react-native-sdk/method-reference.md');
});
