// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

#if os(iOS)
import Flutter
import Foundation
import gxfx
import gxns
import WebRTC

/// Voice effects on the capture stream (native/gxfx). Runs right after noise
/// suppression, from GxNoiseProcessor's audio callback, so the order is fixed.
/// process() = WebRTC capture thread, never allocates; the rest = `queue`.
final class GxVoiceFx {
    static let shared = GxVoiceFx()
    private static let presets = [
        "none", "studio", "hall", "robot", "girl", "transformer", "boy", "child", "woman", "man", "foreigner", "ethereal", "magnetic", "fresh", "energetic", "rich", "muffled", "round", "falsetto", "full", "clear", "resonant", "loudClear", "softRoom", "largeRoom", "valley", "basement", "ktv", "enhancedKtv", "popular", "rock", "vocalConcert", "gramophone", "autotuneMajorC", "autotuneMinorA", "autotuneHarmonicMinor",
    ]
    private let watchdogUs: Int32 = 6000
    private let watchdogConsecutive: Int32 = 5

    private let queue = DispatchQueue(label: "gravix.fx.control", qos: .userInitiated)
    private let used: OpaquePointer = gxns_flag_new(0)!
    private var fx: OpaquePointer? // written once, before `used`
    private var channel: FlutterMethodChannel?
    private var musicActive = false

    private init() {}

    func install(channel: FlutterMethodChannel) { queue.async { self.channel = channel } }

    /// Capture thread.
    func process(_ audioBuffer: RTCAudioBuffer) {
        guard gxns_flag_get(used) != 0, let fx else { return }
        let frames = audioBuffer.frames
        let channels = audioBuffer.channels
        guard frames > 0, channels > 0 else { return }
        let ch0 = audioBuffer.rawBuffer(forChannel: 0)
        let rc = gx_fx_process(fx, ch0, Int32(frames), Int32(frames * 100))
        if rc == Int32(GX_FX_OK) {
            if channels > 1 { for c in 1 ..< channels { audioBuffer.rawBuffer(forChannel: c).update(from: ch0, count: frames) } }
        } else if rc == Int32(GX_FX_NEED_REBUILD) {
            queue.async { gx_fx_rebuild(fx) }
        } else if rc == Int32(GX_FX_WATCHDOG) {
            queue.async {
                NSLog("[GravixFX] watchdog budget_us=\(self.watchdogUs) consecutive=\(self.watchdogConsecutive): effect off")
                self.emit("watchdog")
            }
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
        let args = call.arguments as? [String: Any?] ?? [:]
        switch call.method {
        case "fxConfigure":
            queue.async {
                let reply = self.configure(args["effect"] as? String ?? "none")
                DispatchQueue.main.async { result(reply) }
            }
        case "fxStats":
            queue.async {
                var m = self.stateMap()
                m["ok"] = true
                m["reason"] = "ok"
                DispatchQueue.main.async { result(m) }
            }
        case "fxBenchmark":
            let name = args["effect"] as? String ?? "girl"
            let rate = (args["rate"] as? Int) ?? 48000
            let seconds = (args["seconds"] as? Int) ?? 5
            DispatchQueue.global(qos: .utility).async {
                let reply = Self.benchmark(name, rate: rate, seconds: seconds)
                DispatchQueue.main.async { result(reply) }
            }
        default:
            return false
        }
        return true
    }

    func setMusicActive(_ on: Bool) {
        queue.async {
            guard self.musicActive != on else { return }
            self.musicActive = on
            guard let fx = self.fx else { return }
            gx_fx_set_bypass(fx, on ? 1 : 0)
            NSLog("[GravixFX] step=music bypass=\(on)")
            self.emit("music")
        }
    }

    private func configure(_ name: String) -> [String: Any] {
        guard let preset = Self.presets.firstIndex(of: name) else { return ["ok": false, "reason": "unknown_effect"] }
        if preset == 0, fx == nil { return ["ok": true, "effect": "none", "active": "none", "reason": "ok"] }
        if fx == nil {
            let created = gx_fx_create()
            gx_fx_set_watchdog(created, watchdogUs, watchdogConsecutive)
            gx_fx_set_bypass(created, musicActive ? 1 : 0)
            fx = created
        }
        let rc = gx_fx_set_preset(fx, Int32(preset))
        gxns_flag_set(used, 1)
        NSLog("[GravixFX] step=configure effect=\(name) rc=\(rc) music=\(musicActive)")
        var m = stateMap()
        m["ok"] = rc == 0
        m["installed"] = true
        m["reason"] = rc == 0 ? "ok" : "failed"
        return m
    }

    private func stateMap() -> [String: Any] {
        guard let fx else { return ["effect": "none", "active": "none"] }
        var s = gx_fx_status()
        gx_fx_get_status(fx, &s)
        return ["effect": Self.presets[Int(s.requested)], "active": Self.presets[Int(s.active)], "rate": s.rate,
                "musicBypass": s.bypass != 0, "watchdog": s.watchdog != 0, "latencyMs": s.latency_ms,
                "frames": s.frames, "over": s.over, "maxUs": s.max_us]
    }

    private func emit(_ type: String) {
        var m = stateMap()
        m["type"] = type
        DispatchQueue.main.async { self.channel?.invokeMethod("onVoiceEffects", arguments: m) }
    }

    private static func benchmark(_ name: String, rate: Int, seconds: Int) -> [String: Any] {
        guard let preset = presets.firstIndex(of: name) else { return ["ok": false, "reason": "unknown_effect"] }
        var b = gx_fx_bench()
        let rc = gx_fx_benchmark(Int32(preset), Int32(rate), Int32(seconds), &b)
        NSLog("[GravixFX] step=benchmark effect=\(name) rate=\(rate) p50=\(b.p50_us) p95=\(b.p95_us) max=\(b.max_us) rc=\(rc)")
        return ["ok": rc == 0, "effect": name, "rate": rate, "blocks": b.blocks, "p50Us": b.p50_us,
                "p95Us": b.p95_us, "maxUs": b.max_us, "latencyMs": b.latency_ms]
    }
}

#endif
