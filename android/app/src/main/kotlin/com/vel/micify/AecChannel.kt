package com.vel.micify

import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.media.audiofx.AutomaticGainControl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class AecChannel(private val channel: MethodChannel) : MethodCallHandler {

    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var agc: AutomaticGainControl? = null

    companion object {
        const val CHANNEL_NAME = "com.vel.micify/aec"
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "attach" -> {
                val audioSessionId = call.argument<Int>("audioSessionId")
                if (audioSessionId == null) {
                    result.error("INVALID_ARGS", "audioSessionId is required", null)
                    return
                }
                attach(audioSessionId, result)
            }
            "release" -> {
                release()
                result.success(null)
            }
            "isAvailable" -> {
                result.success(
                    AcousticEchoCanceler.isAvailable()
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun attach(audioSessionId: Int, result: Result) {
        try {
            release()

            // Attach hardware Acoustic Echo Canceler
            if (AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(audioSessionId)
                aec?.enabled = true
            }

            // Attach hardware Noise Suppressor
            if (NoiseSuppressor.isAvailable()) {
                ns = NoiseSuppressor.create(audioSessionId)
                ns?.enabled = true
            }

            // Attach hardware Automatic Gain Control (disabled — we control gain in Dart)
            if (AutomaticGainControl.isAvailable()) {
                agc = AutomaticGainControl.create(audioSessionId)
                agc?.enabled = false
            }

            result.success(mapOf(
                "aecAttached" to (aec != null),
                "nsAttached" to (ns != null),
            ))
        } catch (e: Exception) {
            result.error("AEC_ERROR", e.message, null)
        }
    }

    private fun release() {
        aec?.release(); aec = null
        ns?.release();  ns = null
        agc?.release(); agc = null
    }
}
