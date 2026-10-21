// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

#if os(iOS)
import AVFoundation
import Flutter
import flutter_webrtc
import Foundation
import gxns
import UIKit
import WebRTC

/// On-device noise suppression on iOS (plan §1b, Phase 2b item 13).
///
/// Installed once into flutter_webrtc's APM capture post-processing slot
/// (`AudioManager.sharedInstance().capturePostProcessingAdapter`), i.e. AFTER
/// VPIO (AEC/NS/AGC) and WebRTC's software APM:
///
///   mic -> VPIO -> APM (AEC, [NS], [AGC]) -> GxNoiseProcessor (gx_ns) -> encoder
///
/// Until Dart configures it (`nsConfigure`), `audioProcessingProcess` returns
/// after one atomic load: the processor is pure pass-through and allocates
/// nothing. The gx_ns instance is created on the first configure (off the
/// audio thread) and lives for the process.
///
/// Order (owner decision, default `ownAfterNs`): our NS, then our VAD-gated
/// AGC + limiter (inside gx_ns). Dart turns WebRTC's software NS + AGC off on
/// the track; VPIO's AGC is turned off on the input node in configureInput.
/// VPIO's own NS CANNOT be turned off alone on iOS (only the whole voice
/// processing unit, which also kills AEC), so on iOS ours always runs after
/// Apple's voice-processing NS. `webrtcBeforeNs` keeps WebRTC/VPIO AGC and
/// disables ours.
///
/// Threads: process() = WebRTC capture thread (never allocates/locks/logs);
/// control + watchdog = `queue`; Flutter events = main.
final class GxNoiseProcessor: NSObject, ExternalAudioProcessingDelegate {
    static let shared = GxNoiseProcessor()

    // MARK: audio-thread state (written before `enabled` is published)

    private var ns: OpaquePointer? // struct gx_ns *
    private let enabled: OpaquePointer = gxns_flag_new(0)!
    /// Last channel count seen (multi-channel capture: ch0 is processed and copied).
    private let channelsSeen: OpaquePointer = gxns_flag_new(0)!
    private let initRate: OpaquePointer = gxns_flag_new(0)!
    /// Snapshot for configureInput (engine thread must not wait on `queue`).
    private let wantVpioAgcOff: OpaquePointer = gxns_flag_new(0)!

    // MARK: control state (`queue` only)

    private let queue = DispatchQueue(label: "gravix.ns.control", qos: .utility)
    private var installed = false
    private var channel: FlutterMethodChannel?
    private var config = Config()
    private var studioBox: GxNsStudioBox?
    private var retiredBoxes: [(box: GxNsStudioBox, block: UInt32)] = []
    private var studioReason = ""
    private var demotion: String? // watchdog / thermal / battery_saver while studio was wanted
    private var watchdogRetryUsed = false
    private var watchdogDemotedAt: Date?
    private var timer: DispatchSourceTimer?
    private var lastStatus = gx_ns_status()
    private var lastOver: UInt32 = 0
    private var lastRate: Int32 = 0
    private var lastSummary = Date()
    private var startedAt = Date()
    private var route = "unknown"
    private var musicActive = false
    private var observers: [NSObjectProtocol] = []
    private let packQueue = DispatchQueue(label: "gravix.ns.pack", qos: .utility)
    private var packInFlight = false
    private var packFailed: String?

    struct Config {
        var engine = "off" // off | rnnoise | dfn3 (resolved by Dart)
        var agcEnabled = true
        var agcOrder = "ownAfterNs"
        var musicBypass = true
        var vpioAgcOff = true
        var watchdogUs: Int32 = 8000
        var watchdogConsecutive: UInt32 = 3
        var thermalFallback = true
        var batterySaverFallback = true
        var benchmarkP95Us = 3000
        var benchmarkCachedP95Us: Int?
        var studioModel = "std" // std (bundled) | ll (downloaded pack)
        var studioLlUrl: String?
        var studioDownload = "unmeteredIdle" // never | unmeteredIdle | any
        var studioComputeUnits = "cpuOnly"
        var studioAttenLimitDb: Float = 40 // GX_NS_DEFAULT_ATTEN_LIM_DB; 0 = none
        var studioP95BudgetUs: Int32 = 3000 // rolling p95 over the window -> RNNoise (studio_slow)
        var studioP95WindowMs: Int32 = 2000
    }

    private override init() { super.init() }

    // MARK: install (plugin registration, main thread)

    func install(channel: FlutterMethodChannel) {
        queue.sync { self.channel = channel }
        guard !installed else { return }
        installed = true
        // Before any capture starts: the adapter only forwards initialize() to
        // processors already present, and the APM may initialize early.
        AudioManager.sharedInstance().capturePostProcessingAdapter.addProcessing(self)
        log("install", detail: "slot=capturePostProcessing passthrough=1")
    }

    // MARK: ExternalAudioProcessingDelegate

    func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {
        gxns_flag_set(initRate, Int32(sampleRateHz))
        gxns_flag_set(channelsSeen, Int32(channels))
        guard gxns_flag_get(enabled) != 0, let ns else { return }
        // A new APM stream (HFP 16 k, re-created engine): fade back in.
        gx_ns_request_reset(ns)
        queue.async { self.log("init", rate: Int32(sampleRateHz), detail: "ch=\(channels) src=apm") }
    }

    func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
        guard gxns_flag_get(enabled) != 0, let ns else { return }
        let frames = audioBuffer.frames
        let channels = audioBuffer.channels
        guard frames > 0, channels > 0 else { return }
        // Full band after APM band merge: frames per 10 ms = rate / 100, so
        // 160 = 16 kHz (HFP), 441 = 44.1 kHz, 480 = 48 kHz. Any supported rate.
        let rate = Int32(frames * 100)
        let ch0 = audioBuffer.rawBuffer(forChannel: 0)
        if gx_ns_process(ns, ch0, Int32(frames), rate) != 0 { return }
        if channels > 1 {
            for c in 1 ..< channels {
                audioBuffer.rawBuffer(forChannel: c).update(from: ch0, count: frames)
            }
        }
    }

    func audioProcessingRelease() {
        queue.async { self.log("release", detail: "apm=release") }
    }

    // MARK: Flutter methods

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
        let args = call.arguments as? [String: Any?] ?? [:]
        switch call.method {
        case "nsConfigure":
            queue.async {
                self.configure(args)
                let state = self.stateMap()
                DispatchQueue.main.async { result(state) }
            }
        case "nsSetMusicBypass":
            let on = (args["on"] as? Bool) ?? false
            queue.async { self.setMusicActive(on, source: "dart"); DispatchQueue.main.async { result(nil) } }
        case "nsGetState":
            queue.async { let s = self.stateMap(); DispatchQueue.main.async { result(s) } }
        case "nsDeviceFacts":
            // Facts for the shared Dart resolver (same keys as Android).
            result(Self.deviceFacts())
        case "nsBenchmark":
            // The studio benchmark on its own engine instance, off the audio
            // path; Dart caches it and sends benchmarkCachedP95Us back.
            // config belongs to `queue`: read it there, then load off it
            queue.async {
                let units = self.config.studioComputeUnits
                DispatchQueue.global(qos: .utility).async {
                    let loaded = GxNsStudioEngines.loadBundled(computeUnits: units)
                    guard let engine = loaded.engine else {
                        DispatchQueue.main.async { result(["ok": false, "reason": loaded.reason]) }
                        return
                    }
                    let r = GxNsBenchmark.run(engine)
                    self.log("bench", detail: "p95=\(r.p95Us)us max=\(r.maxUs)us ok=\(r.outputOk ? 1 : 0) frames=\(r.frames) quietIn=\(String(format: "%.1f", r.quietInDb))dB quietOut=\(String(format: "%.1f", r.quietOutDb))dB model=\(engine.name) src=dart")
                    let m: [String: Any] = [
                        "ok": true, "model": "std", "sha256": engine.modelSha256, "p95Us": r.p95Us,
                        "maxUs": r.maxUs, "outputOk": r.outputOk, "runtime": "coreml",
                    ]
                    DispatchQueue.main.async { result(m) }
                }
            }
        default:
            return false
        }
        return true
    }

    // MARK: control (queue)

    private func configure(_ a: [String: Any?]) {
        var c = config
        if let v = a["engine"] as? String { c.engine = v }
        if let v = a["agcOrder"] as? String { c.agcOrder = v }
        // off / kill switch: WebRTC's AGC is back on there, ours must not stack on it (review #1)
        let agcWanted = (a["agc"] as? Bool) ?? (c.agcOrder != "webrtcBeforeNs")
        c.agcEnabled = c.engine != "off" && agcWanted
        if let v = a["musicBypass"] as? Bool { c.musicBypass = v }
        if let v = a["vpioAgcOff"] as? Bool { c.vpioAgcOff = v }
        if let v = a["watchdogUs"] as? Int { c.watchdogUs = Int32(v) }
        if let v = a["watchdogConsecutive"] as? Int { c.watchdogConsecutive = UInt32(max(1, v)) }
        if let v = a["thermalFallback"] as? Bool { c.thermalFallback = v }
        if let v = a["batterySaverFallback"] as? Bool { c.batterySaverFallback = v }
        if let v = a["benchmarkP95Us"] as? Int { c.benchmarkP95Us = v }
        c.benchmarkCachedP95Us = a["benchmarkCachedP95Us"] as? Int
        if let v = a["studioModel"] as? String { c.studioModel = v }
        if a.keys.contains("studioLlUrl") { c.studioLlUrl = a["studioLlUrl"] as? String }
        if let v = a["studioDownload"] as? String { c.studioDownload = v }
        if let v = a["studioComputeUnits"] as? String { c.studioComputeUnits = v }
        if let v = a["studioAttenLimitDb"] as? NSNumber { c.studioAttenLimitDb = v.floatValue }
        if let v = a["studioP95BudgetUs"] as? Int { c.studioP95BudgetUs = Int32(max(0, v)) }
        if let v = a["studioP95WindowMs"] as? Int { c.studioP95WindowMs = Int32(max(200, v)) }
        let studioChanged = c.studioModel != config.studioModel || c.studioComputeUnits != config.studioComputeUnits
        let wasEngine = config.engine
        config = c
        gxns_flag_set(wantVpioAgcOff, (c.vpioAgcOff && c.agcEnabled && c.engine != "off") ? 1 : 0)

        if ns == nil {
            if c.engine == "off" {
                // Never enabled + off = stay pure pass-through (legacy sound).
                log("static", detail: "requested=off passthrough=1")
                return
            }
            var cfg = gx_ns_config()
            gx_ns_default_config(&cfg)
            cfg.initial_engine = GX_NS_ENGINE_RNNOISE
            cfg.agc_enabled = c.agcEnabled ? 1 : 0
            cfg.watchdog_us = c.watchdogUs
            cfg.max_external_latency = 1440 + 480 // DFN3 std 30 ms (+ margin)
            cfg.ext_p95_window = c.studioP95WindowMs / 10 // 10 ms blocks
            guard let st = gx_ns_create(&cfg) else {
                log("install", detail: "error=gx_ns_create_failed")
                return
            }
            ns = st
            startObservers()
            startTimer()
            startedAt = Date()
            route = Self.currentRoute()
            gxns_flag_set(enabled, 1) // publishes `ns` to the audio thread
        }
        guard let ns else { return }
        gx_ns_set_agc(ns, c.agcEnabled ? 1 : 0)
        gx_ns_set_agc_order(ns, GX_NS_AGC_AFTER_NS)
        gx_ns_set_atten_limit(ns, c.studioAttenLimitDb)
        gx_ns_set_ext_p95_budget(ns, c.studioP95BudgetUs)
        if !c.musicBypass, musicActive { gx_ns_set_bypass(ns, 0) }
        if c.musicBypass, musicActive { gx_ns_set_bypass(ns, 1) }
        log("policy", detail: "engine=\(c.engine) agc=\(c.agcEnabled ? 1 : 0) order=\(c.agcOrder) music=\(c.musicBypass ? 1 : 0) wd=\(c.watchdogUs)us/\(c.watchdogConsecutive)")

        switch c.engine {
        case "off":
            detachStudio(reason: "mode_off")
            gx_ns_set_engine(ns, GX_NS_ENGINE_OFF)
        case "dfn3":
            gx_ns_set_engine(ns, GX_NS_ENGINE_RNNOISE) // meanwhile
            if wasEngine != "dfn3" || studioBox == nil { demotion = nil; watchdogRetryUsed = false }
            if studioChanged { detachStudio(reason: "studio_model_changed") }
            // after the nsConfigure reply: the Core ML load + benchmark never delay it
            queue.async { self.startStudio() }
        default:
            detachStudio(reason: "mode_standard")
            gx_ns_set_engine(ns, GX_NS_ENGINE_RNNOISE)
        }
    }

    /// Studio: load the bundled engine, benchmark it (also for an explicit
    /// studio request), attach only if p95 < limit and output sane.
    private func startStudio() {
        guard let ns, config.engine == "dfn3" else { return } // changed while queued
        if studioBox != nil {
            if demotion == nil { gx_ns_set_engine(ns, GX_NS_ENGINE_DFN3) }
            return
        }
        var loaded = GxNsStudioEngines.loadBundled(computeUnits: config.studioComputeUnits)
        if config.studioModel == "ll" {
            if let url = GxNsStudioPack.cachedModel(GxNsStudioPack.ll) {
                let ll = GxNsStudioEngines.loadCompiled(url, spec: GxNsStudioPack.ll, computeUnits: config.studioComputeUnits)
                if ll.engine != nil { loaded = ll } else { log("pack", detail: "id=\(GxNsStudioPack.ll.id) load=failed reason=\(ll.reason) using=std") }
            } else {
                fetchLlPack() // std meanwhile
            }
        }
        guard let engine = loaded.engine else {
            studioReason = "studio_unavailable"
            log("static", detail: "studio=unavailable reason=\(loaded.reason) fallback=rnnoise")
            emit(["type": "engineChanged", "from": "dfn3", "to": "rnnoise", "reason": "studio_unavailable", "detail": loaded.reason])
            return
        }
        let limit = config.benchmarkP95Us
        let p95: Int
        var outputOk = true
        if let cached = config.benchmarkCachedP95Us {
            p95 = cached
            log("bench", detail: "p95=\(cached)us cached=1 limit=\(limit)us model=\(engine.name)")
        } else {
            let r = GxNsBenchmark.run(engine)
            p95 = r.p95Us
            outputOk = r.outputOk
            log("bench", detail: "p95=\(r.p95Us)us max=\(r.maxUs)us ok=\(r.outputOk ? 1 : 0) frames=\(r.frames) quietIn=\(String(format: "%.1f", r.quietInDb))dB quietOut=\(String(format: "%.1f", r.quietOutDb))dB limit=\(limit)us model=\(engine.name)")
            emit(["type": "benchmark", "p95Us": r.p95Us, "maxUs": r.maxUs, "outputOk": r.outputOk, "model": engine.name, "modelSha256": engine.modelSha256])
        }
        guard config.engine == "dfn3" else { return } // changed meanwhile
        guard outputOk else { return reject("benchmark_bad_output") }
        guard p95 < limit else { return reject("benchmark_slow") }
        let box = GxNsStudioBox(engine)
        var ext = box.cEngine()
        guard gx_ns_set_external_engine(ns, &ext) == 0 else { return reject("latency_too_large") }
        studioBox = box
        studioReason = ""
        if demotion == nil { gx_ns_set_engine(ns, GX_NS_ENGINE_DFN3) }
    }

    /// Download + verify + compile the LL pack in the background; switch to it
    /// when ready if studio/ll is still wanted.
    private func fetchLlPack() {
        guard !packInFlight, packFailed == nil else { return }
        guard #available(iOS 16.0, *) else { return }
        let urlString = config.studioLlUrl
        let policy = GxNsStudioPack.Download(rawValue: config.studioDownload) ?? .unmeteredIdle
        packInFlight = true
        log("pack", detail: "id=\(GxNsStudioPack.ll.id) fetch=start policy=\(policy.rawValue) url=\(urlString == nil ? "none" : "set")")
        packQueue.async {
            var failure: String?
            do {
                _ = try GxNsStudioPack.ensure(GxNsStudioPack.ll, remote: urlString.flatMap(URL.init(string:)), policy: policy) { line in
                    self.queue.async { self.log("pack", detail: line.replacingOccurrences(of: "pack ", with: "")) }
                }
            } catch {
                failure = (error as NSError).localizedDescription
            }
            self.queue.async {
                self.packInFlight = false
                if let failure {
                    self.packFailed = failure
                    self.log("pack", detail: "id=\(GxNsStudioPack.ll.id) fetch=failed reason=\(failure) using=std")
                    self.emit(["type": "download", "id": GxNsStudioPack.ll.id, "ok": false, "reason": failure])
                    return
                }
                self.emit(["type": "download", "id": GxNsStudioPack.ll.id, "ok": true])
                guard self.config.engine == "dfn3", self.config.studioModel == "ll" else { return }
                self.detachStudio(reason: "ll_ready")
                self.startStudio()
            }
        }
    }

    private func reject(_ reason: String) {
        studioReason = reason
        log("switch", detail: "from=dfn3 to=rnnoise reason=\(reason)")
        emit(["type": "engineChanged", "from": "dfn3", "to": "rnnoise", "reason": reason])
    }

    private func detachStudio(reason: String) {
        guard let ns, let box = studioBox else { return }
        gx_ns_set_external_engine(ns, nil)
        // Keep the box alive until the audio thread has passed a block boundary.
        retiredBoxes.append((box, gx_ns_blocks_processed(ns)))
        studioBox = nil
        log("switch", detail: "studio=detached reason=\(reason)")
    }

    private func setMusicActive(_ on: Bool, source: String) {
        guard musicActive != on else { return }
        musicActive = on
        guard let ns, config.musicBypass else { return }
        gx_ns_set_bypass(ns, on ? 1 : 0)
        log("musicBypass", detail: "on=\(on ? 1 : 0) src=\(source)")
        emit(["type": "musicBypass", "on": on])
    }

    /// Demote studio -> RNNoise (watchdog / thermal / battery saver).
    private func demote(_ reason: String) {
        guard let ns, config.engine == "dfn3", studioBox != nil, demotion == nil else { return }
        demotion = reason
        gx_ns_set_engine(ns, GX_NS_ENGINE_RNNOISE)
        log("switch", detail: "from=dfn3 to=rnnoise reason=\(reason)")
        emit(["type": "engineChanged", "from": "dfn3", "to": "rnnoise", "reason": reason])
    }

    private func restoreIfAllowed() {
        guard let ns, config.engine == "dfn3", studioBox != nil, let d = demotion else { return }
        if d == "studio_slow" || d == "studio_suppress" {
            return // gx_ns keeps it until the engine is re-attached (next configure)
        }
        if d == "watchdog" {
            // One retry per call, after a cooldown.
            guard !watchdogRetryUsed, let at = watchdogDemotedAt, Date().timeIntervalSince(at) > 60 else { return }
            watchdogRetryUsed = true
        } else if fallbackCondition() != nil {
            return
        }
        demotion = nil
        gx_ns_set_engine(ns, GX_NS_ENGINE_DFN3)
        log("switch", detail: "from=rnnoise to=dfn3 reason=\(d)_cleared")
        emit(["type": "engineChanged", "from": "rnnoise", "to": "dfn3", "reason": "\(d)_cleared"])
    }

    private func fallbackCondition() -> String? {
        let info = ProcessInfo.processInfo
        if config.thermalFallback, info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return "thermal" }
        if config.batterySaverFallback, info.isLowPowerModeEnabled { return "battery_saver" }
        return nil
    }

    // MARK: watchdog + logs (queue, 1 s)

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let ns else { return }
        var s = gx_ns_status()
        gx_ns_get_status(ns, &s)
        var st = gx_ns_stats()
        gx_ns_get_stats(ns, &st)

        if s.rate != lastRate, s.rate > 0 {
            log("init", rate: s.rate, detail: "src=frames apmInit=\(gxns_flag_get(initRate)) ch=\(gxns_flag_get(channelsSeen)) latency=\(s.latency_samples)")
            lastRate = s.rate
        }
        if s.active.rawValue != lastStatus.active.rawValue, s.crossfading == 0 {
            let from = String(cString: gx_ns_engine_name(lastStatus.active))
            let to = String(cString: gx_ns_engine_name(s.active))
            let reason = String(cString: gx_ns_reason_name(s.reason))
            log("switch", rate: s.rate, detail: "from=\(from) to=\(to) reason=\(demotion ?? reason) done=1")
            emit(["type": "engineChanged", "from": from, "to": to, "reason": demotion ?? reason])
            lastStatus = s
        } else if s.crossfading == 0 {
            lastStatus = s
        }

        // Watchdog: N consecutive calls over budget, or N over-budget calls
        // within the last second.
        let overDelta = st.over_budget &- lastOver
        lastOver = st.over_budget
        if st.consecutive_over >= config.watchdogConsecutive || overDelta >= config.watchdogConsecutive {
            if s.active.rawValue == GX_NS_ENGINE_DFN3.rawValue || s.requested.rawValue == GX_NS_ENGINE_DFN3.rawValue {
                watchdogDemotedAt = Date()
                demote("watchdog")
            } else if overDelta > 0 {
                log("watchdog", rate: s.rate, detail: "over=\(overDelta) consecutive=\(st.consecutive_over) max=\(st.max_us)us engine=rnnoise action=none")
            }
        }
        // gx_ns rolling p95 of the studio engine over the window above budget
        // (thermal drift mid-call): it already plays RNNoise; record why.
        if st.ext_slow != 0, demotion == nil, config.engine == "dfn3" {
            log("watchdog", rate: s.rate, detail: "studio_slow p95=\(st.ext_p95_us)us>budget=\(config.studioP95BudgetUs)us window=\(config.studioP95WindowMs)ms model=\(config.studioModel) -> rnnoise")
            demote("studio_slow")
        }
        // gx_ns live guard: the studio output speech collapsed vs its input for
        // 2 s of speech (an engine erasing quiet speech); it already plays RNNoise.
        if st.ext_suppress != 0, demotion == nil, config.engine == "dfn3" {
            log("watchdog", rate: s.rate, detail: "studio_suppress model=\(config.studioModel) -> rnnoise")
            demote("studio_suppress")
        }
        restoreIfAllowed()

        // Free retired studio engines once the audio thread moved on.
        let blocks = gx_ns_blocks_processed(ns)
        retiredBoxes.removeAll { $0.block != blocks }

        if Date().timeIntervalSince(lastSummary) >= 60 {
            lastSummary = Date()
            logSummary(s, st)
        }
    }

    private func logSummary(_ s: gx_ns_status, _ st: gx_ns_stats) {
        log("summary", rate: s.rate, detail: "p50=\(st.p50_us)us p95=\(st.p95_us)us p99=\(st.p99_us)us max=\(st.max_us)us over=\(st.over_budget) frames=\(st.frames) underflows=\(st.underflows) extErr=\(st.ext_errors) switches=\(st.engine_switches) agc=\(String(format: "%.1f", s.agc_gain_db))dB pre=\(String(format: "%.1f", s.pregain_db))dB agcApplied=\(String(format: "%.1f", s.agc_applied_db))dB preApplied=\(String(format: "%.1f", s.pregain_applied_db))dB pauseAtt=\(String(format: "%.1f", s.pause_att_db))dB cpu=\(String(format: "%.1f", Self.processCpuPercent()))%")
    }

    // MARK: route / engine hooks

    private func startObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            self?.queue.async { self?.routeChanged(reason: raw) }
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.powerChanged() }
        })
        observers.append(nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.powerChanged() }
        })
    }

    private func routeChanged(reason raw: UInt) {
        guard let ns else { return }
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        // Category / override changes without a device change still re-route
        // the input on some devices: reset on everything but a no-op config.
        let newRoute = Self.currentRoute()
        if reason == .categoryChange, newRoute == route { return }
        route = newRoute
        gx_ns_request_reset(ns)
        log("routeReset", detail: "why=\(Self.reasonName(reason)) hwRate=\(Int(AVAudioSession.sharedInstance().sampleRate))")
        emit(["type": "routeReset", "route": newRoute, "why": Self.reasonName(reason)])
    }

    private func powerChanged() {
        if let why = fallbackCondition() {
            demote(why)
        } else {
            restoreIfAllowed()
        }
    }

    /// GxAudioEngineObserver configureInput: the input format (and maybe the
    /// voice processing unit) was rebuilt.
    func engineConfigureInput(_ engine: AVAudioEngine, format: AVAudioFormat) {
        guard gxns_flag_get(enabled) != 0 else { return }
        var vpioAgc = "n/a"
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled {
            if gxns_flag_get(wantVpioAgcOff) != 0, input.isVoiceProcessingAGCEnabled {
                input.isVoiceProcessingAGCEnabled = false
                vpioAgc = "off"
            } else {
                vpioAgc = input.isVoiceProcessingAGCEnabled ? "on" : "off"
            }
        }
        let rate = Int32(format.sampleRate)
        queue.async {
            if let ns = self.ns { gx_ns_request_reset(ns) }
            self.route = Self.currentRoute()
            self.log("routeReset", rate: rate, detail: "why=configureInput ch=\(format.channelCount) vpioAgc=\(vpioAgc)")
        }
    }

    /// Music mixer session started / stopped (native, no Dart round trip).
    func musicSession(active: Bool) {
        queue.async { self.setMusicActive(active, source: "mixer") }
    }

    // MARK: state / logs / events

    private func stateMap() -> [String: Any] {
        var m: [String: Any] = [
            "platform": "ios",
            "installed": installed,
            "enabled": gxns_flag_get(enabled) != 0,
            "requested": config.engine,
            "route": route,
            "apmInitRate": Int(gxns_flag_get(initRate)),
            "musicActive": musicActive,
            "studioAvailable": GxNsStudioEngines.bundledModelURL() != nil,
            "studioModel": config.studioModel,
            "studioEngine": studioBox?.engine.name ?? "",
            "llCached": GxNsStudioPack.cachedModel(GxNsStudioPack.ll) != nil,
            "studioAttached": studioBox != nil,
        ]
        if !studioReason.isEmpty { m["studioReason"] = studioReason }
        if let demotion { m["demotion"] = demotion }
        if let packFailed { m["packError"] = packFailed }
        guard let ns else { m["active"] = "off"; return m }
        var s = gx_ns_status()
        gx_ns_get_status(ns, &s)
        var st = gx_ns_stats()
        gx_ns_get_stats(ns, &st)
        m["active"] = String(cString: gx_ns_engine_name(s.active))
        m["reason"] = demotion ?? String(cString: gx_ns_reason_name(s.reason))
        m["rate"] = Int(s.rate)
        m["latencySamples"] = Int(s.latency_samples)
        m["crossfading"] = s.crossfading != 0
        m["vad"] = Double(s.vad)
        m["agcGainDb"] = Double(s.agc_gain_db)
        m["preGainDb"] = Double(s.pregain_db)
        m["agcAppliedDb"] = Double(s.agc_applied_db)
        m["preGainAppliedDb"] = Double(s.pregain_applied_db)
        m["pauseAttDb"] = Double(s.pause_att_db)
        m["stats"] = [
            "frames": Int(st.frames), "p50Us": Int(st.p50_us), "p95Us": Int(st.p95_us),
            "p99Us": Int(st.p99_us), "maxUs": Int(st.max_us), "overBudget": Int(st.over_budget),
            "underflows": Int(st.underflows), "extErrors": Int(st.ext_errors),
            "engineSwitches": Int(st.engine_switches),
        ]
        return m
    }

    private func activeEngineName() -> String {
        guard let ns else { return "off" }
        var s = gx_ns_status()
        gx_ns_get_status(ns, &s)
        return String(cString: gx_ns_engine_name(s.active))
    }

    /// `[GravixNS] <step> eng=<..> route=<..> rate=<..> +<ms>ms detail`
    /// (same format as lib/src/noise/gravix_noise_report.dart).
    private func log(_ step: String, rate: Int32? = nil, detail: String = "") {
        let r = rate ?? lastRate
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        NSLog("[GravixNS] %@ eng=%@ route=%@ rate=%@ +%dms %@", step, activeEngineName(), route,
              r > 0 ? "\(r)" : "?", ms, detail)
    }

    private func emit(_ event: [String: Any]) {
        guard let channel else { return }
        DispatchQueue.main.async { channel.invokeMethod("onNsEvent", arguments: event) }
    }

    static func deviceFacts() -> [String: Any] {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let studio = GxNsStudioEngines.bundledModelURL() != nil
        var m: [String: Any] = [
            "model": model,
            "manufacturer": "Apple",
            "osVersion": UIDevice.current.systemVersion,
            "ramMb": Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)),
            "osBuild": "\(model)/\(UIDevice.current.systemVersion)",
            "studioAvailable": studio,
            "studioRuntime": "coreml",
        ]
        if studio {
            m["studioModel"] = "std"
            m["studioSha"] = GxNsStudioEngines.bundledModelSha256
        }
        return m
    }

    static func currentRoute() -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let input = r.inputs.first?.portType
        let output = r.outputs.first?.portType
        switch input {
        case .bluetoothHFP?: return "bt-sco"
        case .bluetoothLE?: return "bt-le"
        case .headsetMic?: return "wired"
        case .usbAudio?: return "usb"
        default: break
        }
        switch output {
        case .bluetoothA2DP?: return "bt-a2dp"
        case .bluetoothLE?: return "bt-le"
        case .headphones?: return "wired"
        case .builtInReceiver?: return "earpiece"
        case .builtInSpeaker?: return "speaker"
        case .usbAudio?: return "usb"
        default: return "unknown"
        }
    }

    static func reasonName(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .newDeviceAvailable: return "newDevice"
        case .oldDeviceUnavailable: return "oldDeviceGone"
        case .categoryChange: return "category"
        case .override: return "override"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "noRoute"
        case .routeConfigurationChange: return "config"
        default: return "unknown"
        }
    }

    /// Process CPU% since the last call (task_info), for the summary line.
    private static var lastCpu: (time: Double, wall: Double)?
    static func processCpuPercent() -> Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        var basic = mach_task_basic_info()
        var bcount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kb = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bcount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &bcount)
            }
        }
        func secs(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
        // live threads + terminated threads
        var cpu = secs(info.user_time) + secs(info.system_time)
        if kb == KERN_SUCCESS { cpu += secs(basic.user_time) + secs(basic.system_time) }
        let wall = Date().timeIntervalSince1970
        defer { lastCpu = (cpu, wall) }
        guard let last = lastCpu, wall > last.wall else { return 0 }
        return (cpu - last.time) / (wall - last.wall) * 100
    }
}
#endif
