package com.gravitycompile.gravix_cloud.rtc

import java.lang.reflect.Field

/**
 * Media-profile echo experiments (2026-10-10 ECHO investigation, all opt-in).
 *
 * Field finding: an app on the Android media profile (flutter_webrtc
 * `bypassVoiceProcessing`: MIC source, stereo, no low-latency playout,
 * software AEC3) sent the room's own playout back to the room almost
 * uncancelled. flutter_webrtc builds WebRTC's audio device module inside its
 * own `initialize` and offers no knob for these, so the experiments change the
 * built module by reflection, BEFORE the first room starts playout/capture:
 *
 *  - `lowLatencyPlayout`: WebRtcAudioTrack.useLowLatency (private, read in
 *    initPlayout): PERFORMANCE_MODE_LOW_LATENCY instead of the deep-buffer
 *    media output (measured 2026-10-10: our track on AUDIO_OUTPUT_FLAG_DEEP_BUFFER,
 *    track latency ~205 ms Infinix / 270-310 ms Xiaomi).
 *  - `captureSource`: WebRtcAudioRecord.audioSource (private FINAL, set in the
 *    constructor, read each time an AudioRecord is built). With a mono
 *    (non-bypass) module this gives mono + MIC + software AEC3, which flutter_webrtc
 *    cannot express (its bypass branch always adds stereo input).
 *  - `aec3FieldTrials`: libwebrtc's global field-trial string, read lazily by
 *    the APM environment when AEC3 is constructed (first capture). It REPLACES
 *    the whole string, so flutter_webrtc's WARP trial is re-added on request.
 *
 * Nothing here runs unless the app asks (Dart sends no call for an "off" tuning).
 */
internal object GxMediaEchoTuning {
  /** flutter_webrtc 1.6.2 FIELD_TRIAL_ICE_HANDSHAKE_DTLS (enableWARP). */
  const val WARP_TRIAL = "WebRTC-IceHandshakeDtls/Enabled/"

  private const val SOURCE_MIC = 1 // MediaRecorder.AudioSource.MIC
  private const val SOURCE_VOICE_COMMUNICATION = 7 // MediaRecorder.AudioSource.VOICE_COMMUNICATION

  /** libwebrtc's FieldTrialsStringIsValid: "Name/Group/" pairs, no conflicting duplicates. */
  fun fieldTrialsValid(trials: String): Boolean {
    if (trials.isEmpty()) return true
    val seen = HashMap<String, String>()
    var next = 0
    while (next < trials.length) {
      val nameEnd = trials.indexOf('/', next)
      if (nameEnd < 0 || nameEnd == next) return false
      val groupEnd = trials.indexOf('/', nameEnd + 1)
      if (groupEnd < 0 || groupEnd == nameEnd + 1) return false
      val name = trials.substring(next, nameEnd)
      val group = trials.substring(nameEnd + 1, groupEnd)
      val prev = seen.put(name, group)
      if (prev != null && prev != group) return false
      next = groupEnd + 1
    }
    return true
  }

  fun mergeFieldTrials(keepWarp: Boolean, extra: String): String =
    if (keepWarp && !extra.contains(WARP_TRIAL)) WARP_TRIAL + extra else extra

  /** A declared field of [target]'s class or a superclass, made accessible (also private final). */
  private fun field(target: Any, name: String): Field {
    var cls: Class<*>? = target.javaClass
    while (cls != null) {
      try {
        return cls.getDeclaredField(name).apply { isAccessible = true }
      } catch (_: NoSuchFieldException) {
        cls = cls.superclass
      }
    }
    throw NoSuchFieldException("${target.javaClass.name}.$name")
  }

  private fun publicField(target: Any, name: String): Any? = try {
    target.javaClass.getField(name).get(target)
  } catch (_: Throwable) {
    field(target, name).get(target)
  }

  /**
   * Applies the set keys of [args] (`lowLatencyPlayout` Boolean,
   * `captureSource` "mic" | "voiceCommunication", `aec3FieldTrials` String,
   * `keepWarpTrial` Boolean) to [adm] (an org.webrtc.audio.JavaAudioDeviceModule).
   * Returns per key: "applied", "appliedFromNextPlayout"/"appliedFromNextCapture"
   * (the player/recorder was already running: the next start uses it),
   * "refused: ..." or "failed: ...", plus the previous values (`...Was`).
   */
  fun apply(adm: Any, args: Map<String, Any?>, initFieldTrials: (String) -> Unit): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>()

    (args["lowLatencyPlayout"] as? Boolean)?.let { want ->
      out["lowLatencyPlayout"] = try {
        val track = publicField(adm, "audioOutput") ?: throw IllegalStateException("no audioOutput")
        val f = field(track, "useLowLatency")
        out["lowLatencyPlayoutWas"] = f.getBoolean(track)
        f.setBoolean(track, want)
        if (field(track, "audioTrack").get(track) == null) "applied" else "appliedFromNextPlayout"
      } catch (t: Throwable) {
        "failed: ${t.javaClass.simpleName} ${t.message}"
      }
    }

    (args["captureSource"] as? String)?.let { name ->
      val source = when (name) {
        "mic" -> SOURCE_MIC
        "voiceCommunication" -> SOURCE_VOICE_COMMUNICATION
        else -> null
      }
      out["captureSource"] = if (source == null) {
        "refused: unknown source $name"
      } else {
        try {
          val record = publicField(adm, "audioInput") ?: throw IllegalStateException("no audioInput")
          val f = field(record, "audioSource")
          out["captureSourceWas"] = f.getInt(record)
          f.setInt(record, source)
          if (field(record, "audioRecord").get(record) == null) "applied" else "appliedFromNextCapture"
        } catch (t: Throwable) {
          "failed: ${t.javaClass.simpleName} ${t.message}"
        }
      }
    }

    (args["aec3FieldTrials"] as? String)?.let { extra ->
      out["fieldTrials"] = if (!fieldTrialsValid(extra)) {
        "refused: malformed field-trial string"
      } else {
        try {
          initFieldTrials(mergeFieldTrials(args["keepWarpTrial"] == true, extra))
          "applied"
        } catch (t: Throwable) {
          "failed: ${t.javaClass.simpleName} ${t.message}"
        }
      }
    }
    return out
  }
}
