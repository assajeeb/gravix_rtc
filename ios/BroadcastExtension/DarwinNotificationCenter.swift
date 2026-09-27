// Darwin (cross-process) notifications shared with the app's BroadcastManager.
// The names must match the plugin's DarwinNotificationCenter.swift.

import Foundation

enum DarwinNotification {
    static let broadcastStarted = "iOS_BroadcastStarted"
    static let broadcastStopped = "iOS_BroadcastStopped"
    static let broadcastRequestStop = "iOS_BroadcastRequestStop"
}

enum DarwinNotificationCenter {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true
        )
    }
}

/// Calls `handler` on the main queue each time `name` is posted, until released.
final class DarwinNotificationObserver {
    private let name: String
    private let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.handler() }
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString), nil
        )
    }
}
