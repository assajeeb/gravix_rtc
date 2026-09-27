// Gravix screen-share Broadcast Upload Extension (template).
//
// Copy this folder into your app's Broadcast Upload Extension target (see
// README.md next to this file). It is NOT compiled into the gravix_rtc plugin.
//
// Protocol (what flutter_webrtc 1.6.0's FlutterSocketConnectionFrameReader in
// the app expects):
//  - The app listens on a Unix domain socket at
//    <app group container>/rtc_SSFD once the screen track is created.
//  - Each frame is an HTTP-style message: headers Content-Length,
//    Buffer-Width, Buffer-Height, Buffer-Orientation
//    (CGImagePropertyOrientation raw value), body = JPEG.
//  - Darwin notifications tie the extension to the SDK's BroadcastManager:
//    iOS_BroadcastStarted / iOS_BroadcastStopped are posted from here,
//    iOS_BroadcastRequestStop is observed (BroadcastManager.requestStop()).
//
// The app group comes from this extension's Info.plist key
// RTCAppGroupIdentifier, the same key the app's Info.plist carries.

import ReplayKit

private enum Constants {
    static let appGroupInfoKey = "RTCAppGroupIdentifier"
    static let socketFileName = "rtc_SSFD"
}

class SampleHandler: RPBroadcastSampleHandler {
    private var clientConnection: SocketConnection?
    private var uploader: SampleUploader?
    private var connectTimer: DispatchSourceTimer?
    private var requestStopObserver: DarwinNotificationObserver?

    private var socketFilePath: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: Constants.appGroupInfoKey) as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent(Constants.socketFileName).path
    }

    override func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        guard let path = socketFilePath, let connection = SocketConnection(filePath: path) else {
            finishBroadcastWithError(NSError(
                domain: RPRecordingErrorDomain, code: RPRecordingErrorCode.failedToStart.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "RTCAppGroupIdentifier is missing or the app group is not enabled for this extension."]
            ))
            return
        }
        clientConnection = connection
        uploader = SampleUploader(connection: connection)
        connection.didClose = { [weak self] error in
            // The app stopped sharing (or went away): end the broadcast.
            self?.finish(error)
        }

        requestStopObserver = DarwinNotificationObserver(name: DarwinNotification.broadcastRequestStop) { [weak self] in
            self?.finish(nil)
        }

        // Tells the app's BroadcastManager to create + publish the screen track,
        // which is what opens the socket this extension connects to.
        DarwinNotificationCenter.post(DarwinNotification.broadcastStarted)
        connectWhenAppListens()
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        tearDown()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        uploader?.send(sample: sampleBuffer)
    }

    // The app starts listening only after it received broadcastStarted and
    // created the track, so retry until the connection succeeds.
    private func connectWhenAppListens() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.clientConnection else { return }
            attempts += 1
            if connection.open() {
                self.connectTimer?.cancel()
                self.connectTimer = nil
            } else if attempts > 60 { // ~30 s
                self.finish(NSError(
                    domain: RPRecordingErrorDomain, code: RPRecordingErrorCode.failedToStart.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "The app did not start screen sharing."]
                ))
            }
        }
        connectTimer = timer
        timer.resume()
    }

    private func finish(_ error: Error?) {
        tearDown()
        // RPBroadcastSampleHandler requires a non-nil error to end the broadcast.
        finishBroadcastWithError(error ?? NSError(
            domain: RPRecordingErrorDomain, code: RPRecordingErrorCode.userDeclined.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Screen sharing stopped."]
        ))
    }

    private func tearDown() {
        connectTimer?.cancel()
        connectTimer = nil
        requestStopObserver = nil
        clientConnection?.didClose = nil
        clientConnection?.close()
        clientConnection = nil
        uploader = nil
        DarwinNotificationCenter.post(DarwinNotification.broadcastStopped)
    }
}
