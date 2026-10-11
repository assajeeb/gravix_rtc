// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

#if os(iOS)
import AVFoundation
import Flutter
import UIKit
import WebRTC

/// Microphone state and audio routes on iOS (0.4.15, field report 2026-10-10,
/// items 7c/7d).
///
/// - Interruptions (a call, Siri, an alarm) are reported to Dart as
///   `onMicSignals {sessionInterrupted}`; until now nothing told the app.
/// - After an interruption ends, the session is re-activated only when nobody
///   else did: RTCAudioSession re-activates itself when it holds an
///   activation, and the audio engine device observes the same notification,
///   so acting at once would race them (a second activation during WebRTC's
///   own restart is how -9001-style failures happen). Never under CallKit.
/// - Routes: `getAudioRoutes` / `setAudioRoute` / `onAudioRoutesChanged`.
@available(iOS 13.0, *)
extension GravixClientPlugin {
    /// The route the app selected through setAudioRoute (nil = automatic).
    static var explicitRoute: String?
    /// True while a setAudioRoute selection set the preferred input, so only
    /// that one is ever cleared (an app's own preferred input stays).
    static var pinnedPreferredInput = false

    // MARK: - Interruptions

    func handleStartMicMonitor(args: [String: Any?], result: @escaping FlutterResult) {
        micMonitorRecover = (args["recoverAfterInterruption"] as? Bool) ?? true
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        }
        result(["sessionInterrupted": false])
    }

    func handleStopMicMonitor(result: @escaping FlutterResult) {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        result(nil)
    }

    private func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value)
        else { return }
        switch type {
        case .began:
            // iOS 14.5+: a "began" for an app that was merely suspended is not
            // a live interruption of the microphone.
            if #available(iOS 14.5, *),
               let reasonValue = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt,
               AVAudioSession.InterruptionReason(rawValue: reasonValue) == .appWasSuspended
            {
                return
            }
            print("[Gravix] audio session interruption began")
            channel?.invokeMethod("onMicSignals", arguments: ["sessionInterrupted": true])
        case .ended:
            print("[Gravix] audio session interruption ended")
            channel?.invokeMethod("onMicSignals", arguments: ["sessionInterrupted": false])
            if micMonitorRecover { scheduleSessionReactivation(reason: "interruptionEnded") }
        @unknown default:
            break
        }
    }

    /// Re-activates the session ~1 s later, only if the engine runs, the
    /// session is still inactive, and Gravix owns activation.
    func scheduleSessionReactivation(reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let observer = self?.audioEngineObserver,
                  observer.isSessionActive,
                  observer.canActivateSession
            else { return }
            let session = RTCAudioSession.sharedInstance()
            guard !session.isActive else { return }
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            do {
                try session.setActive(true)
                print("[Gravix] audio session re-activated (\(reason))")
            } catch {
                print("[Gravix] audio session re-activation failed (\(reason)): \(error)")
            }
        }
    }

    // MARK: - Routes

    static func routeName(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "earpiece"
        case .headphones, .headsetMic: return "wiredHeadset"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return "bluetooth"
        case .usbAudio: return "usb"
        default: return "unknown"
        }
    }

    func routesSnapshot(reason: String) -> [String: Any?] {
        let avSession = AVAudioSession.sharedInstance()
        let outputs = avSession.currentRoute.outputs
        let inputs = avSession.availableInputs ?? []
        var routes = ["speaker"]
        if UIDevice.current.userInterfaceIdiom == .phone { routes.append("earpiece") }
        if inputs.contains(where: { $0.portType == .headsetMic }) || outputs.contains(where: { $0.portType == .headphones }) {
            routes.append("wiredHeadset")
        }
        if inputs.contains(where: { $0.portType == .bluetoothHFP })
            || outputs.contains(where: { [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0.portType) })
        {
            routes.append("bluetooth")
        }
        if inputs.contains(where: { $0.portType == .usbAudio }) || outputs.contains(where: { $0.portType == .usbAudio }) {
            routes.append("usb")
        }
        let current = outputs.first.map { GravixClientPlugin.routeName($0.portType) } ?? "unknown"
        return [
            "routes": routes,
            "current": current,
            "explicit": GravixClientPlugin.explicitRoute,
            "reason": reason,
        ]
    }

    func handleSetAudioRoute(args: [String: Any?], result: @escaping FlutterResult) {
        let route = args["route"] as? String
        switch route {
        case "speaker":
            GravixClientPlugin.explicitRoute = route
            releasePreferredInputPin()
            handleSetAppleAudioOutput(args: ["speaker": true] as [String: Any?]) { [weak self] reply in
                result(self?.routeReply(reply) ?? reply)
                self?.emitRoutesSelected()
            }
            return
        case "earpiece":
            GravixClientPlugin.explicitRoute = route
            releasePreferredInputPin()
            handleSetAppleAudioOutput(args: ["speaker": false] as [String: Any?]) { [weak self] reply in
                result(self?.routeReply(reply) ?? reply)
                self?.emitRoutesSelected()
            }
            return
        default:
            break
        }

        // Every other selection must drop a forced speaker first: the route
        // change it causes would otherwise re-force the speaker
        // (handleRouteChange) within one notification.
        audioEngineObserver?.updateForceSpeakerOutput(false)
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        GravixClientPlugin.releaseBuiltInMicPinLocked(session)
        let avSession = session.session
        let inputs = avSession.availableInputs ?? []
        do {
            switch route {
            case nil, "speakerOff":
                // automatic: a connected headset wins; "speakerOff" = the
                // receiver (not the loudspeaker) when none is connected
                GravixClientPlugin.explicitRoute = route
                if GravixClientPlugin.pinnedPreferredInput {
                    GravixClientPlugin.pinnedPreferredInput = false
                    try avSession.setPreferredInput(nil)
                }
                if route == "speakerOff", session.mode == AVAudioSession.Mode.videoChat.rawValue {
                    try session.setMode(.voiceChat)
                }
                try session.overrideOutputAudioPort(.none)
            case "bluetooth", "wiredHeadset", "usb":
                let wanted: [AVAudioSession.Port] = route == "bluetooth"
                    ? [.bluetoothHFP]
                    : route == "usb" ? [.usbAudio] : [.headsetMic]
                GravixClientPlugin.explicitRoute = route
                if let port = inputs.first(where: { wanted.contains($0.portType) }) {
                    try avSession.setPreferredInput(port)
                    GravixClientPlugin.pinnedPreferredInput = true
                }
                try session.overrideOutputAudioPort(.none)
            default:
                result(["applied": false, "reason": "unknownRoute"])
                return
            }
        } catch {
            result(FlutterError(code: "setAudioRoute", message: error.localizedDescription, details: nil))
            return
        }
        let snapshot = routesSnapshot(reason: "selected")
        let current = snapshot["current"] as? String
        // 2026-10-11 (route API nit, iPhone run log): speakerOff answered applied=true
        // whatever the route; it holds only when the route is known and not the speaker.
        let applied = route == nil || current == route
            || (route == "speakerOff" && current != nil && current != "speaker" && current != "unknown")
        var reply: [String: Any?] = ["applied": applied, "current": current]
        if !applied { reply["reason"] = "routeIs:\(current ?? "unknown")" }
        result(reply)
        channel?.invokeMethod("onAudioRoutesChanged", arguments: snapshot)
    }

    /// 2026-10-11 (route API nit, iPhone run log 65/95/208-210): the Dart side moves the
    /// speaker policy BEFORE this call, so the route change it causes reached listeners
    /// with the PREVIOUS explicit route, and nothing followed the new one. Android emits a
    /// "selected" snapshot after every selection; so does iOS now.
    private func emitRoutesSelected() {
        channel?.invokeMethod("onAudioRoutesChanged", arguments: routesSnapshot(reason: "selected"))
    }

    private func releasePreferredInputPin() {
        guard GravixClientPlugin.pinnedPreferredInput else { return }
        GravixClientPlugin.pinnedPreferredInput = false
        try? AVAudioSession.sharedInstance().setPreferredInput(nil)
    }

    /// Maps a setAppleAudioOutput answer to the setAudioRoute shape.
    private func routeReply(_ reply: Any?) -> Any? {
        guard let map = reply as? [String: Any] else { return reply }
        let applied = (map["applied"] as? Bool ?? false) || (map["deferred"] as? Bool ?? false)
        return [
            "applied": applied,
            "current": routesSnapshot(reason: "")["current"] ?? nil,
            "reason": map["reason"],
        ]
    }
}
#endif
