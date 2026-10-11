// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

/**
 * Decides when a route snapshot is a change worth an `onAudioRoutesChanged`
 * event, and which triggers to listen to. Pure, for the JVM tests.
 *
 * Interruption-sim run 2026-10-10 (emulator API 36, virtual HFP+A2DP
 * headset): in MEDIA mode (MODE_NORMAL, Android routes media itself) an
 * A2DP-only headset connecting or disconnecting moved the playout but emitted
 * no event: the only trigger was AudioSwitch's communication-device list,
 * which an A2DP-only change does not touch. Media mode now also listens to
 * the platform's output-device callback; communication mode is unchanged.
 */
internal class RouteChangeTracker {
  private var last: Map<String, Any?>? = null

  /** Whether an output-device added/removed callback should re-read the route. */
  fun acceptsOutputDeviceChange(routingHandled: Boolean): Boolean = !routingHandled

  /** True when [snapshot] differs from the last emitted one (the reason is not a change). */
  @Synchronized
  fun offer(snapshot: Map<String, Any?>): Boolean {
    // never a current route outside the available list (phone run 2026-10-10)
    val current = snapshot["current"]
    val routes = snapshot["routes"] as? List<*>
    if (current != AudioRoutePolicy.UNKNOWN && routes != null && current !in routes) return false
    val key = snapshot - "reason"
    if (key == last) return false
    last = key
    return true
  }

  @Synchronized
  fun reset() {
    last = null
  }

  companion object {
    /** The media routing (getAudioDevicesForAttributes) lags the device callback: re-read then. */
    val LATE_RECHECKS_MS = listOf(500L, 1500L)
  }
}
