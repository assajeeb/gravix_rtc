// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

#if os(iOS)
import AVFoundation
import Flutter
import WebRTC

/// Direct speaker / receiver selection and route-change reporting (iOS).
///
/// `setAppleAudioOutput {speaker: Bool}` answers a map the Dart side can act on:
///   - `applied`:  the live route now matches the request.
///   - `deferred`: no call session yet (category is not playAndRecord); the
///                 selection is cached and applied when the audio engine starts.
///   - `route`:    comma-separated output port types after the change.
///   - `reason`:   why `applied` is false, when it is.
@available(iOS 13.0, *)
extension GravixClientPlugin {
    public func handleSetAppleAudioOutput(args: [String: Any?], result: @escaping FlutterResult) {
        let speaker = (args["speaker"] as? Bool) ?? true
        // Keep the engine observer in step so its next lifecycle re-apply does
        // not undo the selection (it re-issues overrideOutputAudioPort).
        audioEngineObserver?.updateForceSpeakerOutput(speaker)

        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }

        guard session.category == AVAudioSession.Category.playAndRecord.rawValue else {
            result([
                "applied": false,
                "deferred": true,
                "route": GravixClientPlugin.describeOutputs(session.currentRoute),
                "reason": "sessionNotInCall",
            ])
            return
        }

        do {
            if speaker {
                // Drop a built-in-mic pin left by an earlier earpiece selection,
                // or a Bluetooth headset stays excluded for the whole session.
                GravixClientPlugin.releaseBuiltInMicPinLocked(session)
                try session.overrideOutputAudioPort(.speaker)
            } else {
                // videoChat defaults playback to the loudspeaker; voiceChat to
                // the receiver. Switch before clearing the override.
                if session.mode == AVAudioSession.Mode.videoChat.rawValue {
                    try session.setMode(.voiceChat)
                }
                // A Bluetooth HFP headset owns both directions; preferring the
                // built-in mic moves output back to the receiver. The pin is
                // sticky, so the speaker branch and every configureNativeAudio
                // (policy change / clearAudioOutput) clear it again.
                let current = session.currentRoute
                let onBluetooth = current.outputs.contains { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
                if onBluetooth,
                   let builtInMic = session.session.availableInputs?.first(where: { $0.portType == .builtInMic })
                {
                    try session.setPreferredInput(builtInMic)
                    GravixClientPlugin.pinnedBuiltInMic = true
                }
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            result(FlutterError(code: "setAppleAudioOutput", message: error.localizedDescription, details: nil))
            return
        }

        let route = session.currentRoute
        let wanted: AVAudioSession.Port = speaker ? .builtInSpeaker : .builtInReceiver
        let applied = route.outputs.contains { $0.portType == wanted }
        var response: [String: Any] = [
            "applied": applied,
            "deferred": false,
            "route": GravixClientPlugin.describeOutputs(route),
        ]
        if !applied {
            // Typically a wired headset: iOS offers no way to force the
            // receiver over it.
            response["reason"] = "routeIs:\(GravixClientPlugin.describeOutputs(route))"
        }
        result(response)
    }

    /// True while an earpiece selection has pinned the built-in mic. Only a pin
    /// this plugin set is ever cleared, so an app's own preferred input
    /// (e.g. an external mic chosen through flutter_webrtc) is left alone.
    static var pinnedBuiltInMic = false

    /// Clears the built-in-mic pin. Caller holds the RTCAudioSession lock.
    static func releaseBuiltInMicPinLocked(_ session: RTCAudioSession) {
        guard pinnedBuiltInMic else { return }
        pinnedBuiltInMic = false
        if session.session.preferredInput?.portType == .builtInMic {
            try? session.session.setPreferredInput(nil)
        }
    }

    static func releaseBuiltInMicPin() {
        guard pinnedBuiltInMic else { return }
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        releaseBuiltInMicPinLocked(session)
    }

    static func describeOutputs(_ route: AVAudioSessionRouteDescription) -> String {
        route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
    }

    /// Observes AVAudioSession route changes: re-asserts a forced speaker
    /// (iOS drops `overrideOutputAudioPort(.speaker)` whenever the route
    /// changes) and reports the change to Dart as `onAudioRouteChanged`.
    func startObservingRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    func stopObservingRouteChanges() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) ?? .unknown

        let session = RTCAudioSession.sharedInstance()
        var reasserted = false
        if reason != .override,
           audioEngineObserver?.isForceSpeakerOutput == true,
           session.category == AVAudioSession.Category.playAndRecord.rawValue,
           !session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker })
        {
            session.lockForConfiguration()
            reasserted = (try? session.overrideOutputAudioPort(.speaker)) != nil
            session.unlockForConfiguration()
        }

        channel?.invokeMethod("onAudioRouteChanged", arguments: [
            "reason": GravixClientPlugin.describe(reason),
            "outputs": GravixClientPlugin.describeOutputs(session.currentRoute),
            "speakerReasserted": reasserted,
        ])
    }

    static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
#endif
