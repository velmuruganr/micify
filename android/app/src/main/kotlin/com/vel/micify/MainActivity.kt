package com.vel.micify

import android.bluetooth.BluetoothA2dp
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.os.Build
import android.os.IBinder
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var aecChannel: AecChannel? = null
    private var audioRouteChannel: AudioRouteChannel? = null

    // Service binding
    private var relayService: MicRelayService? = null
    private var serviceBound = false
    private var serviceChannel: MethodChannel? = null

    // Bluetooth auto-start
    private var btReceiver: BluetoothReceiver? = null
    private var wasRelayRunning = false

    // Phone call resume
    private var phoneReceiver: PhoneStateReceiver? = null
    private var relayInterruptedByCall = false

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            relayService = (binder as MicRelayService.LocalBinder).getService()
            serviceBound = true
            relayService?.onLevelUpdate = { level ->
                runOnUiThread {
                    serviceChannel?.invokeMethod("onLevel", level)
                }
            }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            relayService = null
            serviceBound = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Legacy AEC channel (kept for compatibility)
        val aecMc = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AecChannel.CHANNEL_NAME,
        )
        aecChannel = AecChannel(aecMc)

        // Audio route channel
        val routeMc = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AudioRouteChannel.CHANNEL_NAME,
        )
        audioRouteChannel = AudioRouteChannel(applicationContext, routeMc)

        // Service control channel
        val svcMc = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.vel.micify/relay_service",
        )
        serviceChannel = svcMc
        svcMc.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startRelayService()
                    relayService?.let { svc ->
                        svc.echoCancelEnabled   = call.argument("echoCancel") ?: true
                        svc.noiseSuppressEnabled = call.argument("noiseSuppress") ?: true
                        applySettingsFromCall(svc, call)
                        svc.startRelay()
                        wasRelayRunning = true
                        // Report maxAllowedGain back so Flutter can cap the slider
                        runOnUiThread {
                            serviceChannel?.invokeMethod("onMaxGain", svc.maxAllowedGain.toDouble())
                        }
                    }
                    result.success(null)
                }
                "stop" -> {
                    wasRelayRunning = false
                    relayService?.stopRelay()
                    stopRelayService()
                    result.success(null)
                }
                "setGain" -> {
                    relayService?.gain = (call.argument<Double>("gain") ?: 1.5).toFloat()
                    result.success(null)
                }
                "applySettings" -> {
                    relayService?.let { applySettingsFromCall(it, call) }
                    result.success(null)
                }
                "isRunning" -> result.success(relayService?.isRunning ?: false)
                else -> result.notImplemented()
            }
        }

        // Register phone state receiver — stop relay during calls, resume after
        phoneReceiver = PhoneStateReceiver(
            onCallStarted = {
                relayInterruptedByCall = relayService?.isRunning == true
                if (relayInterruptedByCall) {
                    relayService?.stopRelay()
                    runOnUiThread {
                        serviceChannel?.invokeMethod("onRelayInterruptedByCall", null)
                    }
                }
            },
            onCallEnded = {
                if (relayInterruptedByCall) {
                    relayInterruptedByCall = false
                    // Small delay to let telephony audio release before we reclaim mic
                    android.os.Handler(mainLooper).postDelayed({
                        relayService?.startRelay()
                        runOnUiThread {
                            serviceChannel?.invokeMethod("onRelayResumedAfterCall", null)
                        }
                    }, 800)
                }
            },
        )
        registerReceiver(
            phoneReceiver,
            IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED),
        )

        // Register Bluetooth receiver for auto-start on reconnect
        btReceiver = BluetoothReceiver(
            onConnected = {
                if (wasRelayRunning) {
                    runOnUiThread {
                        serviceChannel?.invokeMethod("onBluetoothConnected", null)
                    }
                }
            },
            onDisconnected = {
                runOnUiThread {
                    serviceChannel?.invokeMethod("onBluetoothDisconnected", null)
                }
            },
        )
        val filter = IntentFilter(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(btReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(btReceiver, filter)
        }

        // Bind to service if already running
        bindService(
            Intent(this, MicRelayService::class.java),
            serviceConnection,
            Context.BIND_AUTO_CREATE,
        )
    }

    private fun applySettingsFromCall(svc: MicRelayService, call: io.flutter.plugin.common.MethodCall) {
        svc.applySettings(
            newGain          = (call.argument<Double>("gain")         ?: svc.gain.toDouble()).toFloat(),
            newLowCutHz      = call.argument<Double>("lowCutHz")      ?: svc.lowCutHz,
            newMaxThreshold  = (call.argument<Double>("maxThreshold") ?: svc.maxThreshold.toDouble()).toFloat(),
            newBassDb        = call.argument<Double>("bassDb")        ?: svc.eqBassDb,
            newMidDb         = call.argument<Double>("midDb")         ?: svc.eqMidDb,
            newTrebleDb      = call.argument<Double>("trebleDb")      ?: svc.eqTrebleDb,
            newPitchRate     = (call.argument<Double>("pitchRate")    ?: svc.pitchRate.toDouble()).toFloat(),
        )
    }

    private fun startRelayService() {
        val intent = Intent(this, MicRelayService::class.java).apply {
            action = MicRelayService.ACTION_START
        }
        startForegroundService(intent)
        if (!serviceBound) {
            bindService(Intent(this, MicRelayService::class.java), serviceConnection, 0)
        }
    }

    private fun stopRelayService() {
        val intent = Intent(this, MicRelayService::class.java).apply {
            action = MicRelayService.ACTION_STOP
        }
        startService(intent)
    }

    override fun onDestroy() {
        audioRouteChannel?.release()
        audioRouteChannel = null
        aecChannel = null
        phoneReceiver?.let { unregisterReceiver(it) }
        phoneReceiver = null
        btReceiver?.let { unregisterReceiver(it) }
        btReceiver = null
        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
        }
        super.onDestroy()
    }
}
