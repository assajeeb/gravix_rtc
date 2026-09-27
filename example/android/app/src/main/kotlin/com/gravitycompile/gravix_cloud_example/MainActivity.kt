package com.gravitycompile.gravix_cloud_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The join-latency harness needs one thing Dart cannot do by itself:
 *
 *  - read the launch intent's extras, so a run can be fully configured by
 *    `adb shell am start ... -e wsUrl ... --ei joins 20` with nobody typing a
 *    token on a phone keyboard;
 *
 * (The fixed-tag logcat line the harness also needs comes from the SDK's own
 * Android plugin - `gravixLogLine` - so a production app gets it too.)
 *
 * Extras are handed over as strings, whatever type `am start` gave them
 * (-e / --ei / --ez), because the Dart side parses them itself.
 * Nothing here logs an extra's VALUE: a token or a secret may be among them.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gravix.example/harness")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getLaunchExtras" -> {
                        val out = HashMap<String, String>()
                        val extras = intent?.extras
                        if (extras != null) {
                            for (key in extras.keySet()) {
                                @Suppress("DEPRECATION")
                                val value = extras.get(key)
                                if (value != null) out[key] = value.toString()
                            }
                        }
                        result.success(out)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
