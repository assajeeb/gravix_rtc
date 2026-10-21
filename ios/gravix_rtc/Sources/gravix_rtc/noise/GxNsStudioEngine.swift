// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import Foundation
import gxns
#if canImport(CoreML)
import CoreML
#endif

/// A studio (external) noise suppression engine plugged into the gx_ns core
/// through `gx_ns_set_external_engine` (plan §2, §4). The core feeds it one
/// 10 ms block: 480 samples at 48 kHz in [-1, 1] scale.
///
/// `process` runs on the real-time capture thread: no allocation, no locks,
/// no Objective-C bridging that allocates. Return 0 on success; anything else
/// makes the core fall back to RNNoise at once (reason `ext_error`).
protocol GxNsStudioEngine: AnyObject {
    /// Short engine id for logs, e.g. "dfn3-coreml-fp16nn".
    var name: String { get }
    /// Model SHA-256 (benchmark cache key), or "" when unknown.
    var modelSha256: String { get }
    /// Algorithmic delay at 48 kHz (DFN3 standard: 1440 samples = 30 ms).
    var latencySamples: Int32 { get }
    func process(_ out: UnsafeMutablePointer<Float>, _ input: UnsafePointer<Float>, _ count: Int32) -> Int32
    /// Clears the streaming state (route change). Audio thread or idle.
    func reset()
}

/// Holds the engine for the C trampolines (`user` pointer). Retained by the
/// processor while attached and until the audio thread has moved past it.
final class GxNsStudioBox {
    let engine: GxNsStudioEngine
    init(_ engine: GxNsStudioEngine) { self.engine = engine }

    func cEngine() -> gx_ns_external_engine {
        gx_ns_external_engine(
            process: { user, out, input, n in
                guard let user, let out, let input else { return -1 }
                let box = Unmanaged<GxNsStudioBox>.fromOpaque(user).takeUnretainedValue()
                return box.engine.process(out, input, n)
            },
            reset: { user in
                guard let user else { return }
                Unmanaged<GxNsStudioBox>.fromOpaque(user).takeUnretainedValue().engine.reset()
            },
            user: Unmanaged.passUnretained(self).toOpaque(),
            latency_samples: engine.latencySamples
        )
    }
}

/// Where studio engines come from.
///
/// - std (default): DeepFilterNet3 standard, Core ML int8-linear / fp16
///   compute with the ERB front end fp32 (DFN3_SPIKE.md §1/§3), BUNDLED as a
///   precompiled `gxns_dfn3.mlmodelc` (resource bundle `gravix_rtc_ns` with
///   CocoaPods, the target's resource bundle with SwiftPM). 30 ms latency.
/// - ll: DeepFilterNet3 low-latency (10 ms), downloaded on demand
///   (GxNsStudioPack: SHA-256 compiled in, URL from config).
/// Core ML mlprogram iOS16: studio needs iOS 16+.
enum GxNsStudioEngines {
    static let bundledModelName = "gxns_dfn3"
    /// SHA-256 of the release dfn3_std_int8.mlpackage.zip the bundled model was compiled from.
    static let bundledModelSha256 = "29c4d6b4951d10123798bafe7560de993f4b712ccf8f9dc269cce88487f9485b"
    static let bundledLatency: Int32 = 1440 // 30 ms at 48 kHz (10 ms window overlap + 20 ms lookahead)

    /// URL of the bundled compiled model, if it was shipped.
    static func bundledModelURL() -> URL? {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        for base in [Bundle(for: GxNsStudioBox.self), Bundle.main] {
            if let sub = base.url(forResource: "gravix_rtc_ns", withExtension: "bundle"), let b = Bundle(url: sub) {
                bundles.append(b)
            }
            bundles.append(base)
        }
        for bundle in bundles {
            if let url = bundle.url(forResource: bundledModelName, withExtension: "mlmodelc") { return url }
            if let url = bundle.url(forResource: bundledModelName, withExtension: "mlmodelc", subdirectory: "ns") { return url }
        }
        return nil
    }

    /// Loads the bundled standard engine. Off the audio thread.
    static func loadBundled(computeUnits: String?) -> (engine: GxNsStudioEngine?, reason: String) {
        guard #available(iOS 16.0, macOS 13.0, *) else { return (nil, "static_old_os") }
        guard let url = bundledModelURL() else { return (nil, "dfn3_not_bundled") }
        do {
            let e = try GxNsDfn3CoreML(compiledModel: url, name: "dfn3-std-coreml", modelSha256: bundledModelSha256,
                                       latencySamples: bundledLatency, computeUnits: units(computeUnits))
            return (e, "ok")
        } catch {
            return (nil, "dfn3_load_failed")
        }
    }

    /// Loads a compiled downloaded pack model. Off the audio thread.
    static func loadCompiled(_ url: URL, spec: GxNsStudioPack.Spec, computeUnits: String?) -> (engine: GxNsStudioEngine?, reason: String) {
        guard #available(iOS 16.0, macOS 13.0, *) else { return (nil, "static_old_os") }
        do {
            let e = try GxNsDfn3CoreML(compiledModel: url, name: spec.id, modelSha256: spec.sha256,
                                       latencySamples: spec.latencySamples, computeUnits: units(computeUnits))
            return (e, "ok")
        } catch {
            return (nil, "pack_load_failed")
        }
    }

    #if canImport(CoreML)
    static func units(_ s: String?) -> MLComputeUnits {
        switch s {
        case "cpuAndNeuralEngine": if #available(iOS 16.0, macOS 13.0, *) { return .cpuAndNeuralEngine } else { return .cpuOnly }
        case "cpuAndGpu": return .cpuAndGPU
        case "all": return .all
        default: return .cpuOnly // spike: CPU_ONLY fastest; ANE jitter unmeasured (Phase 5)
        }
    }
    #endif
}

/// First-run benchmark (plan §4): 20 warm-up + 200 timed blocks on a
/// background thread while RNNoise keeps running; the engine is attached only
/// if p95 < the limit and the output is sane (corrupt model check).
enum GxNsBenchmark {
    struct Result {
        let p95Us: Int
        let maxUs: Int
        let outputOk: Bool
        let frames: Int
        var quietInDb: Double = 0
        var quietOutDb: Double = 0
    }

    /// The synthetic speech-like block generator (voiced harmonic stack +
    /// white noise, ~-20 dBFS before `scale`).
    private struct Gen {
        var seed: UInt32 = 0x9E37_79B9
        var phase: Double = 0
        mutating func fill(_ x: inout [Float], scale: Double) {
            for k in 0 ..< x.count {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.1
                phase += 2 * Double.pi * 180 / 48000
                let voiced = 0.06 * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase))
                x[k] = Float((voiced + noise) * scale)
            }
        }
    }

    /// Quiet-mic check (device run 2026-10-21: DFN3 erased a quiet iPhone mic):
    /// speech-like input at -45 dBFS, lifted by the core's pre-gain for that
    /// level, must keep its energy through the engine (out >= in - 6 dB).
    static func quietCheck(_ engine: GxNsStudioEngine, blocks: Int = 150) -> (inDb: Double, outDb: Double, ok: Bool) {
        let n = Int(GX_NS_BLOCK)
        var input = [Float](repeating: 0, count: n)
        var output = [Float](repeating: 0, count: n)
        // the generator's RMS at scale 1 (measured once over 1 s)
        var probe = Gen()
        var acc = 0.0
        for _ in 0 ..< 100 { probe.fill(&input, scale: 1); for v in input { acc += Double(v) * Double(v) } }
        let rms1 = 10 * log10(acc / Double(100 * n) + 1e-20)
        let quietDb = -45.0
        let scaleDb = quietDb - rms1 + Double(gx_ns_pregain_for_level(Float(quietDb)))
        let scale = pow(10, scaleDb / 20)
        var gen = Gen()
        var ie = 0.0, oe = 0.0
        engine.reset()
        for i in 0 ..< blocks {
            gen.fill(&input, scale: scale)
            let rc = input.withUnsafeBufferPointer { inp in
                output.withUnsafeMutableBufferPointer { out in engine.process(out.baseAddress!, inp.baseAddress!, Int32(n)) }
            }
            if rc != 0 { engine.reset(); return (0, -120, false) }
            if i >= 10 { // past the engine's latency
                for k in 0 ..< n {
                    ie += Double(input[k]) * Double(input[k])
                    oe += Double(output[k]) * Double(output[k])
                }
            }
        }
        engine.reset()
        let cnt = Double((blocks - 10) * n)
        let inDb = 10 * log10(ie / cnt + 1e-20), outDb = 10 * log10(oe / cnt + 1e-20)
        return (inDb, outDb, outDb.isFinite && outDb >= inDb - 6)
    }

    static func run(_ engine: GxNsStudioEngine, warmup: Int = 20, frames: Int = 200) -> Result {
        let n = Int(GX_NS_BLOCK)
        var input = [Float](repeating: 0, count: n)
        var output = [Float](repeating: 0, count: n)
        var times = [Int]()
        times.reserveCapacity(frames)
        var seed: UInt32 = 0x9E37_79B9
        var phase: Double = 0
        var inEnergy: Double = 0
        var outEnergy: Double = 0
        var finite = true
        engine.reset()
        for i in 0 ..< (warmup + frames) {
            // Voiced-like harmonic stack + white noise (~-20 dBFS): the real
            // speech clip arrives with the pack (Phase 3).
            for k in 0 ..< n {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.1
                phase += 2 * Double.pi * 180 / 48000
                let voiced = 0.06 * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase))
                input[k] = Float(voiced + noise)
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rc = input.withUnsafeBufferPointer { inp in
                output.withUnsafeMutableBufferPointer { out in
                    engine.process(out.baseAddress!, inp.baseAddress!, Int32(n))
                }
            }
            let us = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
            if rc != 0 { return Result(p95Us: Int.max, maxUs: us, outputOk: false, frames: i) }
            if i >= warmup {
                times.append(us)
                for k in 0 ..< n {
                    let o = Double(output[k])
                    if !o.isFinite { finite = false }
                    outEnergy += o * o
                    inEnergy += Double(input[k]) * Double(input[k])
                }
            }
        }
        engine.reset()
        times.sort()
        let p95 = times.isEmpty ? Int.max : times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        // Sane output: finite, not silent, not louder than the input + 6 dB.
        let ratio = inEnergy > 0 ? outEnergy / inEnergy : 0
        let q = quietCheck(engine)
        let ok = finite && ratio > 1e-6 && ratio < 4 && q.ok
        return Result(p95Us: p95, maxUs: times.last ?? 0, outputOk: ok, frames: frames, quietInDb: q.inDb, quietOutDb: q.outDb)
    }
}
