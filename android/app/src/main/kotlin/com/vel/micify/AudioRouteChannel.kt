package com.vel.micify

import android.bluetooth.BluetoothManager
import android.content.Context
import android.media.AudioManager
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class AudioRouteChannel(
    private val context: Context,
    channel: MethodChannel,
) : MethodCallHandler {

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    companion object {
        const val CHANNEL_NAME = "com.vel.micify/audio_route"
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: Result) {
        when (call.method) {
            "setMicSource" -> {
                val source = call.argument<String>("source") ?: "builtin"
                setMicSource(source, result)
            }
            "getAvailableSources" -> {
                result.success(getAvailableSources())
            }
            else -> result.notImplemented()
        }
    }

    private fun setMicSource(source: String, result: Result) {
        try {
            when (source) {
                "bluetooth" -> {
                    audioManager.startBluetoothSco()
                    audioManager.isBluetoothScoOn = true
                }
                else -> {
                    // Stop Bluetooth SCO if switching away
                    if (audioManager.isBluetoothScoOn) {
                        audioManager.stopBluetoothSco()
                        audioManager.isBluetoothScoOn = false
                    }
                }
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("ROUTE_ERROR", e.message, null)
        }
    }

    private fun getAvailableSources(): List<String> {
        val sources = mutableListOf("builtin", "wired")
        val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = btManager?.adapter
        if (adapter != null && adapter.isEnabled) {
            sources.add("bluetooth")
        }
        return sources
    }

    fun release() {
        try {
            if (audioManager.isBluetoothScoOn) {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
            }
        } catch (_: Exception) {}
    }
}
