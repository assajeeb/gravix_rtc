// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

#if canImport(CoreML)
import CoreML
import Foundation

/// DeepFilterNet3 streaming model on Core ML (standard: bundled; LL: downloaded).
///
/// Interface (dfn3-spike release manifest, `interface`): 48 kHz mono, 480
/// float32 samples in -> 480 out per call, in order. Every input except
/// `input_frame` / `gx_dft_cos` / `gx_dft_sin` is a state; output
/// `new_<name>` is fed back as `<name>` next frame. Core ML models have no
/// `new_analysis_mem`: the next frame's `analysis_mem` is this frame's input.
/// The STFT runs inside the model as matmuls against the two DFT tables
/// (computed once here); the ERB front end inside the model is fp32.
///
/// Real-time path: two pre-allocated state sets (inputs of one = output
/// backings of the other, swapped every frame), pre-built feature values and
/// one MLPredictionOptions per parity, so a frame copies 2 x 480 floats and
/// calls `prediction`. Core ML may still allocate internally; the gx_ns
/// watchdog (frame time) and the benchmark gate cover that.
@available(iOS 16.0, macOS 13.0, *)
final class GxNsDfn3CoreML: GxNsStudioEngine {
    let name: String
    let modelSha256: String
    let latencySamples: Int32

    private let model: MLModel
    private let frame: MLMultiArray
    private let sets: [StateSet] // [0], [1]
    private let providers: [Provider]
    private let options: [MLPredictionOptions]
    private var parity = 0
    private let stateNames: [String]

    private final class StateSet {
        var arrays: [String: MLMultiArray] = [:]
        var enhanced: MLMultiArray!
    }

    private final class Provider: NSObject, MLFeatureProvider {
        let featureNames: Set<String>
        let values: [String: MLFeatureValue]
        init(_ values: [String: MLFeatureValue]) {
            self.values = values
            featureNames = Set(values.keys)
        }
        func featureValue(for featureName: String) -> MLFeatureValue? { values[featureName] }
    }

    /// Loads a compiled model (.mlmodelc). Off the audio thread.
    init(compiledModel url: URL, name: String, modelSha256: String, latencySamples: Int32,
         computeUnits: MLComputeUnits = .cpuOnly) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: cfg)
        self.name = name
        self.modelSha256 = modelSha256
        self.latencySamples = latencySamples

        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        func shape(_ d: MLFeatureDescription?) throws -> [NSNumber] {
            guard let c = d?.multiArrayConstraint else { throw Self.error("model I/O is not a multi-array") }
            return c.shape
        }
        guard inputs["input_frame"] != nil, inputs["gx_dft_cos"] != nil, inputs["gx_dft_sin"] != nil,
              outputs["enhanced_audio_frame"] != nil, inputs["analysis_mem"] != nil
        else { throw Self.error("unexpected DFN3 model interface") }

        frame = try MLMultiArray(shape: try shape(inputs["input_frame"]), dataType: .float32)
        let (cosT, sinT) = try Self.dftTables(shape: try shape(inputs["gx_dft_cos"]))

        let names = inputs.keys.filter { !["input_frame", "gx_dft_cos", "gx_dft_sin"].contains($0) }.sorted()
        stateNames = names
        var builtSets: [StateSet] = []
        for _ in 0 ..< 2 {
            let s = StateSet()
            for n in names { s.arrays[n] = try MLMultiArray(shape: try shape(inputs[n]), dataType: .float32) }
            s.enhanced = try MLMultiArray(shape: try shape(outputs["enhanced_audio_frame"]), dataType: .float32)
            builtSets.append(s)
        }
        sets = builtSets
        for n in names where n != "analysis_mem" {
            guard outputs["new_\(n)"] != nil else { throw Self.error("missing output new_\(n)") }
        }

        var provs: [Provider] = []
        var opts: [MLPredictionOptions] = []
        for p in 0 ..< 2 {
            let cur = builtSets[p], next = builtSets[1 - p]
            var values: [String: MLFeatureValue] = [
                "input_frame": MLFeatureValue(multiArray: frame),
                "gx_dft_cos": MLFeatureValue(multiArray: cosT),
                "gx_dft_sin": MLFeatureValue(multiArray: sinT),
            ]
            for n in names { values[n] = MLFeatureValue(multiArray: cur.arrays[n]!) }
            provs.append(Provider(values))
            var backings: [String: Any] = ["enhanced_audio_frame": next.enhanced!]
            for n in names where n != "analysis_mem" { backings["new_\(n)"] = next.arrays[n]! }
            let o = MLPredictionOptions()
            o.outputBackings = backings
            opts.append(o)
        }
        providers = provs
        options = opts
        reset()
    }

    func process(_ out: UnsafeMutablePointer<Float>, _ input: UnsafePointer<Float>, _ count: Int32) -> Int32 {
        let n = Int(count)
        guard n == frame.count else { return -2 }
        let p = parity
        let fptr = frame.dataPointer.assumingMemoryBound(to: Float.self)
        fptr.update(from: input, count: n)
        do {
            let result = try autoreleasepool { try model.prediction(from: providers[p], options: options[p]) }
            let next = sets[1 - p]
            // Output backings are normally honoured; copy from the result if not.
            if let enhanced = result.featureValue(for: "enhanced_audio_frame")?.multiArrayValue, enhanced !== next.enhanced {
                guard Self.copyOut(enhanced, to: out, count: n) else { return -3 }
                for name in stateNames where name != "analysis_mem" {
                    if let v = result.featureValue(for: "new_\(name)")?.multiArrayValue, let dst = next.arrays[name], v !== dst {
                        Self.copy(v, into: dst)
                    }
                }
            } else {
                out.update(from: next.enhanced.dataPointer.assumingMemoryBound(to: Float.self), count: n)
            }
            next.arrays["analysis_mem"]!.dataPointer.assumingMemoryBound(to: Float.self).update(from: input, count: n)
            parity = 1 - p
            return 0
        } catch {
            return -1
        }
    }

    func reset() {
        for s in sets {
            for (_, a) in s.arrays { memset(a.dataPointer, 0, a.count * MemoryLayout<Float>.size) }
            if let e = s.arrays["erb_norm_state"] { Self.linspace(e, -60, -90) }
            if let b = s.arrays["band_unit_norm_state"] { Self.linspace(b, 0.001, 0.0001) }
        }
        parity = 0
    }

    // MARK: helpers

    private static func linspace(_ a: MLMultiArray, _ from: Float, _ to: Float) {
        let n = a.count
        let p = a.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0 ..< n { p[i] = n == 1 ? from : from + (to - from) * Float(i) / Float(n - 1) }
    }

    private static func copyOut(_ a: MLMultiArray, to out: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        guard a.count == count else { return false }
        switch a.dataType {
        case .float32: out.update(from: a.dataPointer.assumingMemoryBound(to: Float.self), count: count)
        default: for i in 0 ..< count { out[i] = a[i].floatValue }
        }
        return true
    }

    private static func copy(_ src: MLMultiArray, into dst: MLMultiArray) {
        if src.dataType == .float32, src.count == dst.count {
            memcpy(dst.dataPointer, src.dataPointer, dst.count * MemoryLayout<Float>.size)
        } else {
            let d = dst.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0 ..< min(src.count, dst.count) { d[i] = src[i].floatValue }
        }
    }

    /// cos/sin(2*pi*((n*k) mod N)/N), n < N, k < N/2+1 (shape [N, N/2+1]).
    static func dftTables(shape: [NSNumber]) throws -> (MLMultiArray, MLMultiArray) {
        guard shape.count == 2 else { throw error("unexpected DFT table shape") }
        let rows = shape[0].intValue, cols = shape[1].intValue
        let c = try MLMultiArray(shape: shape, dataType: .float32)
        let s = try MLMultiArray(shape: shape, dataType: .float32)
        let cp = c.dataPointer.assumingMemoryBound(to: Float.self)
        let sp = s.dataPointer.assumingMemoryBound(to: Float.self)
        for n in 0 ..< rows {
            for k in 0 ..< cols {
                let a = Double((n * k) % rows) * (2 * Double.pi / Double(rows))
                cp[n * cols + k] = Float(cos(a))
                sp[n * cols + k] = Float(sin(a))
            }
        }
        return (c, s)
    }

    static func error(_ msg: String) -> NSError {
        NSError(domain: "GravixNS", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
#endif
