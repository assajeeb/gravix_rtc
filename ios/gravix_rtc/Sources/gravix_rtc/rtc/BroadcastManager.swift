/*
 * Copyright 2025 LiveKit
 * Modifications Copyright 2024-2026 Gravity Compile
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Combine
import ReplayKit
import UIKit

@available(iOS 13.0, *)
final class BroadcastManager {

    static let shared = BroadcastManager()

    let isBroadcastingPublisher: AnyPublisher<Bool, Never> =
        Publishers.Merge(
            DarwinNotificationCenter.shared.publisher(for: .broadcastStarted).map { _ in true },
            DarwinNotificationCenter.shared.publisher(for: .broadcastStopped).map { _ in false }
        )
        .eraseToAnyPublisher()

    /// Shows the system broadcast picker preselecting the app's extension.
    /// Returns false (and shows nothing) when Info.plist does not name one.
    @discardableResult
    func requestActivation() -> Bool {
        guard let bundleIdentifier = BroadcastBundleInfo.screenSharingExtension else { return false }
        Task { await Self.showPicker(for: bundleIdentifier) }
        return true
    }

    func requestStop() {
        DarwinNotificationCenter.shared.postNotification(.broadcastRequestStop)
    }

    /// Convenience function to show broadcast extension picker.
    @MainActor private static func showPicker(for preferredExtension: String) {
        let view = RPSystemBroadcastPickerView()
        view.preferredExtension = preferredExtension
        view.showsMicrophoneButton = false

        guard let button = view.subviews.compactMap({ $0 as? UIButton }).first else {
            print("[Gravix] Unable to find button in RPSystemBroadcastPickerView")
            return
        }
        button.sendActions(for: .touchUpInside)
    }
}
