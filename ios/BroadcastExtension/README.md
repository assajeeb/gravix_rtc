# iOS screen share: Broadcast Upload Extension (template)

iOS only lets an app capture the whole screen (other apps, the home screen)
from a **Broadcast Upload Extension**, a separate target inside your app. The
files in this folder are that extension. They are not compiled into the
gravix_rtc plugin; you copy them into your app.

How it fits together:

```
setScreenShareEnabled(true)
  -> BroadcastManager.requestActivation()  shows the system picker (preselects your extension)
user taps "Start Broadcast"
  -> extension: broadcastStarted  posts Darwin notification iOS_BroadcastStarted
  -> app: broadcastStateChanged(true)  creates the screen track (useiOSBroadcastExtension)
     and flutter_webrtc listens on <app group>/rtc_SSFD
  -> extension connects and streams JPEG frames
setScreenShareEnabled(false) / BroadcastManager.requestStop()
  -> iOS_BroadcastRequestStop  extension finishes; posts iOS_BroadcastStopped
```

## 1. Create the target

In Xcode, open `ios/Runner.xcworkspace`:

1. File > New > Target > **Broadcast Upload Extension**. Name it e.g.
   `ScreenShare`. Untick "Include UI Extension". Language Swift.
2. Bundle id: a child of the app's, e.g. `com.example.app.ScreenShare`.
3. Deployment target: the same as Runner (iOS 15 or later recommended).
4. Delete the generated `SampleHandler.swift` and add the four `.swift` files
   from this folder to the **extension target only**.
5. Replace the extension's `Info.plist` with the one here (or copy its keys).
   Set `RTCAppGroupIdentifier` to your App Group id.

## 2. App Group (shared by both targets)

1. Runner target > Signing & Capabilities > + Capability > **App Groups** >
   add `group.com.example.app` (use your own id; it must start with `group.`).
2. Extension target > the same capability with the **same** group.
3. Both provisioning profiles must include that group (Apple Developer portal:
   Identifiers > App Groups, then enable it on both App IDs).

## 3. Runner Info.plist

```xml
<key>RTCAppGroupIdentifier</key>
<string>group.com.example.app</string>
<key>RTCScreenSharingExtension</key>
<string>com.example.app.ScreenShare</string>
```

`RTCScreenSharingExtension` is what the picker preselects. Without it
`BroadcastManager.requestActivation()` throws a `PlatformException` with code
`broadcastExtensionNotConfigured`.

## 4. Dart

```dart
await room.localParticipant?.setScreenShareEnabled(true);   // shows the picker
// ...
await room.localParticipant?.setScreenShareEnabled(false);  // stops the broadcast
```

Set `BroadcastManager().shouldPublishTrack = false` to publish the track
yourself when the broadcast starts.

## Notes

- The extension has a ~50 MB memory limit. Frames are downscaled by 0.5 and
  JPEG-encoded (`SampleUploader.scale` / `jpegQuality`).
- Only video is sent. System audio from the extension is not forwarded.
- Verified here: the template type-checks against the iOS SDK. Running it
  needs a signed build on a real device (the simulator cannot broadcast).
