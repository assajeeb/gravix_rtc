// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

#if os(iOS)
import AVFoundation
import Flutter
import WebRTC

/// iOS counterpart of Android's `MusicMixerPlugin` on channel
/// `com.gravitycompile.gravix_rtc/music` (gravix_rtc 0.4.10; <= 0.4.9 used
/// `gravity.music_mixer`, which collided with the apps' own audio kits).
///
/// ## How the music reaches listeners
///
/// flutter_webrtc 1.6.0 runs WebRTC's AVAudioEngine-based audio device module.
/// Its engine-lifecycle delegate (`GxAudioEngineObserver`, installed by
/// `GravixClientPlugin`) forwards three callbacks here:
///
///  - `configureInputFromSource(..., context:)`: the context carries WebRTC's
///    input mixer node (`RTCAudioEngineInputMixerNodeKey`), the mixer whose
///    output IS the outgoing microphone signal. A music session connects
///    `player -> musicMixer -> inputMixer` onto a free input bus of that mixer,
///    so the music is mixed into what listeners hear. The microphone wiring is
///    never touched.
///  - `configureOutputFromSource(..., toDestination:)`: when `monitor` is on and
///    the playout destination is a mixer, the same player also feeds
///    `monitorMixer -> destination`, so the host hears the music through the
///    voice-processing unit (which then cancels it from the mic, as on Android
///    with hardware AEC).
///  - `willReleaseEngine`: tears the nodes down.
///
/// Nothing is attached to the engine until `start` is called, so `install`
/// (which `GravixRoomService.connect` calls for every room) costs nothing and
/// cannot disturb the microphone.
///
/// ## Limits (stated plainly)
///  - Requires the engine to be running (i.e. the mic published or remote audio
///    playing). `start` before that is queued and begins once the engine runs.
///  - `gain` above 1.0 is clamped to 1.0 (AVAudioMixerNode does not amplify);
///    Android allows up to 2.0.
///  - Verified to compile only. Mixing into the WebRTC input path needs a real
///    device to confirm; see ios/README.md.
///
/// Not on iOS (UNSUPPORTED error): setMicVolume, setDucking. A mic mute on iOS
/// also silences the music for listeners.
///
/// Methods: install -> Bool, start {source|path, musicVolume|gain, monitor, loop}
/// -> {durationMs} (Bool for the legacy `path` form), setLoop {on}, configure,
/// pause / resume / stop -> nil, setVolume {gain}, seekTo {positionMs},
/// isActive -> Bool, getState -> {active,paused,positionMs,durationMs};
/// native -> Dart: onCompleted.
@available(iOS 13.0, *)
final class GravixMusicMixer: NSObject {
    static let shared = GravixMusicMixer()

    private let lock = NSRecursiveLock()
    private weak var channel: FlutterMethodChannel?

    // Engine state captured from the audio device module callbacks.
    private weak var engine: AVAudioEngine?
    private weak var inputMixer: AVAudioMixerNode?
    private var inputFormat: AVAudioFormat?
    private weak var outputDestination: AVAudioMixerNode?
    private var outputFormat: AVAudioFormat?

    // Session state.
    private var session: Session?
    private var pendingStartTimer: DispatchSourceTimer?

    private final class Session {
        let file: AVAudioFile
        let player = AVAudioPlayerNode()
        let musicMixer = AVAudioMixerNode()
        let monitorMixer = AVAudioMixerNode()
        let monitor: Bool
        var gain: Float
        var paused = false
        var loop = false
        var playing = false
        var attached = false
        var connected = false
        var scheduled = false
        var startFrame: AVAudioFramePosition = 0
        var lastPositionFrames: AVAudioFramePosition = 0
        // Bumped on every (re)schedule so a stale completion is ignored.
        var generation = 0

        init(file: AVAudioFile, gain: Float, monitor: Bool) {
            self.file = file
            self.gain = gain
            self.monitor = monitor
        }

        var sampleRate: Double { file.processingFormat.sampleRate }
        var durationMs: Int { Int(Double(file.length) / sampleRate * 1000) }
    }

    // MARK: - Registration

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.gravitycompile.gravix_rtc/music", binaryMessenger: registrar.messenger())
        shared.channel = channel
        channel.setMethodCallHandler { call, result in
            shared.handle(call, result: result)
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = (call.arguments as? [String: Any?]) ?? [:]
        switch call.method {
        case "install":
            // The engine hook is the audio device module delegate, which
            // GravixClientPlugin installs at registration. Nothing to do here.
            result(true)
        case "start":
            let legacy = args["source"] as? String == nil
            guard let path = (args["source"] as? String) ?? (args["path"] as? String) else {
                result(FlutterError(code: "OPEN_FAILED", message: "no source", details: nil))
                return
            }
            let gain = ((args["musicVolume"] as? NSNumber) ?? (args["gain"] as? NSNumber))?.floatValue ?? 1.0
            let monitor = (args["monitor"] as? Bool) ?? true
            let loop = (args["loop"] as? Bool) ?? false
            do {
                try start(path: path, gain: gain, monitor: monitor, loop: loop)
                lock.lock(); let dur = session?.durationMs ?? -1; lock.unlock()
                result(legacy ? true : ["durationMs": dur])
            } catch {
                result(FlutterError(code: "OPEN_FAILED", message: error.localizedDescription, details: nil))
            }
        case "configure":
            result(nil)
        case "setLoop":
            lock.lock(); session?.loop = (args["on"] as? Bool) ?? false; lock.unlock()
            result(nil)
        case "setMicVolume", "setDucking":
            result(FlutterError(code: "UNSUPPORTED", message: "\(call.method) is Android-only", details: nil))
        case "pause":
            pause(); result(nil)
        case "resume":
            resume(); result(nil)
        case "stop":
            stop(); result(nil)
        case "setVolume", "setMusicVolume":
            setGain(((args["volume"] as? NSNumber) ?? (args["gain"] as? NSNumber))?.floatValue ?? 1.0); result(nil)
        case "seekTo", "seek":
            seek(toMs: (args["positionMs"] as? NSNumber)?.intValue ?? 0); result(nil)
        case "isActive":
            result(isActive)
        case "getState":
            result(state())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Audio device module hooks (WebRTC worker thread)

    func engineDidCreate(_ engine: AVAudioEngine) {
        lock.lock(); defer { lock.unlock() }
        self.engine = engine
    }

    func engineWillRelease(_ engine: AVAudioEngine) {
        lock.lock(); defer { lock.unlock() }
        if let session, session.attached {
            detachLocked(session, from: engine)
        }
        self.engine = nil
        inputMixer = nil
        outputDestination = nil
    }

    func engineConfigureInput(_ engine: AVAudioEngine, format: AVAudioFormat, context: [AnyHashable: Any]) {
        lock.lock(); defer { lock.unlock() }
        self.engine = engine
        inputMixer = context[kRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode
        inputFormat = format
        if let session {
            session.connected = false
            connectLocked(session)
            if !session.paused, !session.playing { playWhenEngineRunsLocked(session) }
        }
    }

    func engineConfigureOutput(_ engine: AVAudioEngine, destination: AVAudioNode?, format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        self.engine = engine
        outputDestination = destination as? AVAudioMixerNode
        outputFormat = format
        if let session, session.monitor {
            session.connected = false
            connectLocked(session)
        }
    }

    // MARK: - Control (platform thread)

    private func start(path: String, gain: Float, monitor: Bool, loop: Bool = false) throws {
        let url = path.hasPrefix("file://") ? URL(string: path)! : URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0, file.processingFormat.channelCount > 0, file.length > 0 else {
            throw NSError(domain: "GravixMusicMixer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unsupported or empty audio file"])
        }
        lock.lock(); defer { lock.unlock() }
        stopLocked()
        let session = Session(file: file, gain: min(max(gain, 0), 1), monitor: monitor)
        session.loop = loop
        self.session = session
        connectLocked(session)
        scheduleLocked(session, fromFrame: 0)
        playWhenEngineRunsLocked(session)
    }

    private func pause() {
        lock.lock(); defer { lock.unlock() }
        guard let session, !session.paused else { return }
        session.lastPositionFrames = currentFrameLocked(session)
        session.paused = true
        if session.attached { session.player.pause() }
    }

    private func resume() {
        lock.lock(); defer { lock.unlock() }
        guard let session, session.paused else { return }
        session.paused = false
        playWhenEngineRunsLocked(session)
    }

    private func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func setGain(_ gain: Float) {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return }
        session.gain = min(max(gain, 0), 1)
        session.musicMixer.outputVolume = session.gain
    }

    private func seek(toMs ms: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return }
        let frame = AVAudioFramePosition(Double(max(ms, 0)) / 1000 * session.sampleRate)
        let wasPlaying = session.playing && !session.paused
        if session.attached { session.player.stop() }
        session.playing = false
        scheduleLocked(session, fromFrame: min(frame, max(session.file.length - 1, 0)))
        session.lastPositionFrames = session.startFrame
        if wasPlaying { playWhenEngineRunsLocked(session) }
    }

    private var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil
    }

    private func state() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let session else {
            return ["active": false, "paused": false, "positionMs": 0, "durationMs": -1,
                    "captureReady": inputMixer != nil, "captureLive": inputMixer != nil, "installed": true]
        }
        let frames = session.paused || !session.playing ? session.lastPositionFrames : currentFrameLocked(session)
        return [
            "active": true,
            "paused": session.paused,
            "positionMs": Int(Double(frames) / session.sampleRate * 1000),
            "durationMs": session.durationMs,
            "captureReady": inputMixer != nil,
            "captureLive": inputMixer != nil,
            "installed": true,
        ]
    }

    // MARK: - Graph (lock held)

    private func connectLocked(_ session: Session) {
        guard let engine, let inputMixer, let inputFormat,
              inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              inputMixer.engine === engine
        else { return }
        if !session.attached {
            engine.attach(session.player)
            engine.attach(session.musicMixer)
            engine.attach(session.monitorMixer)
            session.attached = true
        }
        session.musicMixer.outputVolume = session.gain

        var points = [AVAudioConnectionPoint(node: session.musicMixer, bus: 0)]
        if session.monitor, let destination = outputDestination, destination.engine === engine,
           let outputFormat, outputFormat.sampleRate > 0, outputFormat.channelCount > 0
        {
            points.append(AVAudioConnectionPoint(node: session.monitorMixer, bus: 0))
            engine.connect(session.monitorMixer, to: destination, format: outputFormat)
        }
        engine.connect(session.player, to: points, fromBus: 0, format: session.file.processingFormat)
        // Convenience connect onto a mixer takes its next free input bus, so the
        // microphone's own connection into the input mixer is left in place.
        engine.connect(session.musicMixer, to: inputMixer, format: inputFormat)
        session.connected = true
    }

    private func detachLocked(_ session: Session, from engine: AVAudioEngine) {
        // Keep the position so a re-created engine continues where this one stopped.
        if session.playing {
            session.startFrame = min(currentFrameLocked(session), max(session.file.length - 1, 0))
            session.lastPositionFrames = session.startFrame
        }
        session.scheduled = false
        session.player.stop()
        session.playing = false
        for node in [session.player, session.musicMixer, session.monitorMixer] where node.engine === engine {
            engine.detach(node)
        }
        session.attached = false
        session.connected = false
    }

    private func scheduleLocked(_ session: Session, fromFrame frame: AVAudioFramePosition) {
        session.startFrame = frame
        session.generation += 1
        session.scheduled = false
        guard session.attached else { return }
        let generation = session.generation
        let remaining = AVAudioFrameCount(max(session.file.length - frame, 0))
        guard remaining > 0 else { return }
        session.scheduled = true
        session.player.scheduleSegment(session.file, startingFrame: frame, frameCount: remaining, at: nil,
                                       completionCallbackType: .dataPlayedBack)
        { [weak self] _ in
            self?.segmentFinished(generation: generation)
        }
    }

    private func segmentFinished(generation: Int) {
        lock.lock()
        guard let session, session.generation == generation, session.playing, !session.paused else {
            lock.unlock()
            return
        }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.session?.generation == generation
            if stillCurrent, let current = self.session, current.loop {
                // loop: play the file again from the start
                current.playing = false
                self.scheduleLocked(current, fromFrame: 0)
                current.lastPositionFrames = 0
                self.playWhenEngineRunsLocked(current)
                self.lock.unlock()
                return
            }
            if stillCurrent { self.stopLocked() }
            self.lock.unlock()
            if stillCurrent { self.channel?.invokeMethod("onCompleted", arguments: nil) }
        }
    }

    /// AVAudioPlayerNode.play() raises an Objective-C exception (uncatchable in
    /// Swift) unless the node is attached to a running engine, so start only
    /// once that holds, polling briefly while the engine comes up.
    private func playWhenEngineRunsLocked(_ session: Session) {
        pendingStartTimer?.cancel()
        pendingStartTimer = nil
        if tryPlayLocked(session) { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            attempts += 1
            guard let current = self.session, current === session, !current.paused else {
                self.pendingStartTimer?.cancel(); self.pendingStartTimer = nil
                return
            }
            if !current.connected { self.connectLocked(current) }
            if self.tryPlayLocked(current) || attempts > 600 { // give up after ~60 s
                self.pendingStartTimer?.cancel(); self.pendingStartTimer = nil
            }
        }
        pendingStartTimer = timer
        timer.resume()
    }

    private func tryPlayLocked(_ session: Session) -> Bool {
        guard session.attached, session.connected, let engine, engine.isRunning,
              session.player.engine === engine
        else { return false }
        if !session.scheduled {
            scheduleLocked(session, fromFrame: session.startFrame)
            guard session.scheduled else { return false }
        }
        session.player.play()
        session.playing = true
        return true
    }

    private func currentFrameLocked(_ session: Session) -> AVAudioFramePosition {
        guard session.attached, session.playing,
              let nodeTime = session.player.lastRenderTime,
              let playerTime = session.player.playerTime(forNodeTime: nodeTime)
        else { return session.lastPositionFrames }
        // playerTime is in the player's output (file) sample rate.
        return session.startFrame + playerTime.sampleTime
    }

    private func stopLocked() {
        pendingStartTimer?.cancel()
        pendingStartTimer = nil
        guard let session else { return }
        session.generation += 1
        if session.attached {
            if let engine = session.player.engine {
                detachLocked(session, from: engine)
            } else {
                session.attached = false
            }
        }
        self.session = nil
    }
}
#endif
