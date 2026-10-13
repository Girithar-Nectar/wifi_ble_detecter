# attendance_tracker

Detects whether a user is at their workplace and records attendance events.
It uses GPS, connected Wi-Fi, BLE devices, iBeacons, NFC tags and QR codes.
It keeps working in the foreground, in the background and after the app is
killed, on Android and iOS.

## How it works

| Signal | What it proves | Android | iOS |
|---|---|---|---|
| GPS | Within `geofenceRadius` of an office point | Foreground service scan + native geofences | CoreLocation fix + region monitoring |
| Wi-Fi | Connected to a configured SSID / BSSID | `network_info_plus` | `NEHotspotNetwork` (entitlement required) |
| BLE | A configured device name / MAC is advertising | `flutter_blue_plus` | CoreBluetooth (names only; iOS hides MACs) |
| iBeacon | A configured beacon is in range | Advertisement parsing | CoreLocation ranging + beacon region monitoring |
| NFC | The user tapped a registered tag | Reader mode, or tag opens the app | Core NFC tag reader |
| QR | The user scanned a static or rotating code | Verified in Dart | Verified in Dart |

NFC and QR are one-off proofs. After a valid tap or scan, the user counts as
present for `checkpointValidityMinutes` (0 = until the shift ends), even when
no other sensor matches. That makes them the reliable option indoors, where
GPS is poor and there may be no Wi-Fi.

Enter happens on the first matching scan. Exit needs `exitDebounceCount`
consecutive misses. On iOS, a single miss is enough when it comes from a
geofence or beacon region exit.

### Foreground, background and killed

| State | Android | iOS |
|---|---|---|
| Foreground | Foreground service scans every `scanIntervalSeconds` | Native engine scans every `scanIntervalSeconds` |
| Background | Foreground service keeps scanning | A low-power location session (`iosContinuousTracking`) keeps the app running during the shift, so scans continue |
| Swiped away / killed | The foreground service survives a swipe (`stopWithTask=false`). If the OS kills it, a native geofence transition or the watchdog restarts it. Both need the battery-optimisation exemption on Android 12+. | iOS relaunches the app for geofence enter/exit, iBeacon enter/exit, screen-on inside a beacon region, significant location changes (~500 m) and visits. Each relaunch runs one native scan and records the event. |
| Reboot | Service restarts on boot; geofences are re-registered | Region monitoring resumes after the first unlock |
| NFC tap while killed | The `attendancetracker://checkpoint?id=…` tag opens the app, the checkpoint is queued and tracking starts | Background tag reading opens a universal link; forward it to `handleCheckpointUri` |

Events recorded while Dart was not running are kept in a native queue. Read
them with `getPendingEvents()`. If `apiEndpoint` is set, they are also POSTed
to it, natively on iOS, so the server hears about them even while the app
stays killed.

### Limits you cannot code around

- **iOS, killed:** nothing runs on a timer. Detection happens only when iOS
  wakes the app (region, beacon, significant change, visit). For indoor sites,
  iBeacons are the most reliable killed-state signal. Wi-Fi-only sites are
  re-checked only on those wake-ups.
- **iOS:** if the user denies "Always" location, there are no relaunches after
  a kill.
- **Android, force stop:** after Settings → Force stop, the system blocks every
  receiver until the user opens the app again.
- **Android OEM battery savers** (Xiaomi, Oppo, Vivo, Huawei, some Samsung):
  these also need the vendor "Autostart" / "No restrictions" setting, which
  only the user can change.

## Usage

```dart
final tracker = AttendanceTracker();

// Every launch: stores the config natively and verifies NFC taps or links
// that opened the app while it was killed.
await tracker.initialize(AttendanceConfig(
  officePoints: ['POINT(76.9859883 10.9993243)'],
  geofenceRadius: 150,
  wifiBSSIDs: ['3c:64:cf:a6:2b:d0'],
  iBeacons: ['E2C56DB5-DFFB-48D2-B060-D0F5A71096E0:100'],
  nfcTags: ['LOBBY-1', '04:A2:3B:1C:55:80'],      // checkpoint id or tag UID
  qrCodes: ['GATE-2'],                            // printed static codes
  qrSecret: secretFromYourBackend,                // rotating kiosk codes
  qrSiteId: 'HQ',
  checkpointValidityMinutes: 60,
  shiftStartMs: 9 * 3600000,
  shiftEndMs: 18 * 3600000,
  apiEndpoint: 'https://api.example.com/attendance/events', // optional
  apiHeaders: {'Authorization': 'Bearer …'},
));

if (!await tracker.hasPermissions()) await tracker.requestPermissions();
await tracker.requestIgnoreBatteryOptimizations(); // Android; no-op on iOS
await tracker.startTracking();

tracker.onResult.listen((r) => print('in zone: ${r.isInZone} via ${r.source}'));
tracker.onEvent.listen((e) => print(e));
```

### NFC and QR checkpoints

```dart
// NFC: shows the system sheet on iOS, reader mode on Android.
final nfc = await tracker.scanNfc();
if (!nfc.isValid) print('${nfc.verification.message} (UID ${nfc.tagUid})');

// QR: scan with the camera library the app already uses, then hand over the text.
final qr = await tracker.submitQrCode(scannedText);

// Deep links (universal links written on tags, camera-opened QR codes).
await tracker.handleCheckpointUri(uri, source: CheckpointSource.nfc);

// Call on app resume too: taps that arrived while the app was in the background.
await tracker.processPendingCheckpoints();
```

What to write on tags and print on codes:

- **NFC tag:** an NDEF URI record `attendancetracker://checkpoint?id=LOBBY-1`.
  On Android it opens the app even when killed. You can also register the
  tag's UID instead (`nfcTags: ['04:A2:…']`); `scanNfc()` returns `tagUid`
  so you can enrol new tags.
- **Static QR:** `attendancetracker://checkpoint?id=GATE-2`, or just `GATE-2`.
  Anyone can photograph a static code, so prefer rotating codes where it matters.
- **Rotating QR (kiosk / tablet at the entrance):** render
  `AttendanceTracker.generateKioskQrCode(secret: …, siteId: 'HQ', asUri: true)`
  and regenerate it every `qrStepSeconds` (default 30). A photo of the code
  stops working after one step (plus `qrDriftSteps` for clock drift).

### Syncing events

```dart
final events = await tracker.getPendingEvents(); // enter / exit / checkpoint / shiftEnded
await sendToServer(events);
await tracker.acknowledgeEvents(events.map((e) => e.id).toList());
```

Each event carries `appState` (`foreground`, `background`, or `terminated`
when the OS relaunched a killed app), `trigger` (`timer`, `region`,
`significantChange`, `visit`, `geofence`, `nfc`, `qr`, …) and the evidence
seen: location, BSSID, beacon, device and checkpoint id.

`getReadiness()` reports what is still missing for background and killed-state
tracking: "Always" location, notifications, battery optimisation and NFC.

## Host app setup

### Android

`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<!-- Optional: direct "allow" prompt instead of the settings list (Play policy applies). -->
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>

<application …>
  <service
      android:name="id.flutter.flutter_background_service.BackgroundService"
      android:foregroundServiceType="location"
      android:exported="true"
      tools:replace="android:exported"/>
</application>
```

NFC permission, the geofence and boot receivers, and the checkpoint activity
come from the plugin's own manifest.

### iOS

`Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key><string>…</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>…</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>…</string>
<key>NFCReaderUsageDescription</key><string>…</string>
<key>UIBackgroundModes</key>
<array>
  <string>location</string>           <!-- required: keep-alive + relaunch handling -->
  <string>bluetooth-central</string>  <!-- optional: BLE in background -->
</array>
<key>CFBundleURLTypes</key>
<array><dict><key>CFBundleURLSchemes</key><array><string>attendancetracker</string></array></dict></array>
```

Capabilities and entitlements (Xcode → Signing & Capabilities):

- **Access WiFi Information** (`com.apple.developer.networking.wifi-info`).
  Without it, iOS returns no SSID or BSSID.
- **Near Field Communication Tag Reading**
  (`com.apple.developer.nfc.readersession.formats` = `TAG`).
- **Associated Domains**, only if NFC tags should open the killed app on iOS.
  Background tag reading on iPhone XS and later only follows universal links.

You don't need to change AppDelegate. The engine starts itself at launch,
including background relaunches, before Flutter registers plugins.
