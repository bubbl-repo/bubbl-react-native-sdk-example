# Bubbl React Native SDK Example App

Public barebones React Native example for Bubbl SDK integration.

This example is aligned with:
- `guides/react-native-sdk/quickstart.md`
- `guides/react-native-sdk/method-reference.md`
- `guides/react-native-sdk/usage-examples.md`
from `bubbl-docs-redocly`.

## What this app demonstrates

The single-screen method playground exercises every `BubblBridge` method in the method reference:

- `init`, `boot`
- permission methods
- tracking/geofence/campaign methods
- segmentation and correlation methods
- configuration/privacy methods
- event/CTA/survey methods
- diagnostics/log stream methods
- subscription methods (`onNotification`, `onGeofence`, `onDeviceLog`)

## Setup

1. Replace placeholders in:
   - `android/app/google-services.json`
   - `ios/GoogleService-Info.plist`
2. Replace Maps key placeholder in:
   - `android/app/src/main/AndroidManifest.xml`
3. Install dependencies:

```bash
npm install
cd ios && bundle install && bundle exec pod install && cd ..
```

## Test

```bash
npm test -- --watch=false
```

