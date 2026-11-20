// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

#if os(iOS)
import Flutter
import Foundation

/// Process-wide native -> Dart events to every Flutter engine.
///
/// The noise processor, voice effects, audio engine observer and music mixer
/// are process-wide singletons. Each used to keep only the channel of the last
/// engine that registered, so a second engine (a background or push engine)
/// took over their events and the UI engine stopped getting them (e.g. the
/// voice effect `musicBypass` = false event: the app kept showing the effect
/// as paused). Events now go to every live engine; an engine whose Dart side
/// does not listen drops them.
///
/// Channels are held weakly: each one is kept alive by its engine (the plugin
/// instance or its own method call handler), so a torn down engine drops out.
final class GxChannelHub {
    static let client = GxChannelHub()
    static let music = GxChannelHub()

    private let lock = NSLock()
    private let table = NSHashTable<FlutterMethodChannel>.weakObjects()

    func add(_ channel: FlutterMethodChannel) {
        lock.lock()
        table.add(channel)
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return table.allObjects.isEmpty
    }

    /// Any thread; delivered on the main thread.
    func invoke(_ method: String, _ arguments: Any?) {
        lock.lock()
        let channels = table.allObjects
        lock.unlock()
        if channels.isEmpty { return }
        DispatchQueue.main.async {
            for c in channels { c.invokeMethod(method, arguments: arguments) }
        }
    }
}
#endif
