package com.vel.micify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Binder
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tanh

class MicRelayService : Service() {

    inner class LocalBinder : Binder() {
        fun getService() = this@MicRelayService
    }

    private val binder = LocalBinder()

    // Audio config
    private val sampleRate   = 16000
    private val channelIn    = AudioFormat.CHANNEL_IN_MONO
    private val channelOut   = AudioFormat.CHANNEL_OUT_MONO
    private val encoding     = AudioFormat.ENCODING_PCM_16BIT
    private val bufferSize   = AudioRecord.getMinBufferSize(sampleRate, channelIn, encoding)
        .coerceAtLeast(4096)

    // Runtime state
    @Volatile var isRunning  = false
    @Volatile var gain       = 1.5f
    @Volatile var maxThreshold = 0.9f
    @Volatile var lowCutHz   = 80.0
    @Volatile var echoCancelEnabled  = true
    @Volatile var noiseSuppressEnabled = true

    // EQ state
    @Volatile var eqBassDb   = 0.0
    @Volatile var eqMidDb    = 0.0
    @Volatile var eqTrebleDb = 0.0

    // Pitch / voice effect (playback rate — 1.0 = normal)
    @Volatile var pitchRate  = 1.0f

    // Status callback to UI — negative value signals silence timeout
    var onLevelUpdate: ((Float) -> Unit)? = null

    private val silenceTimeoutMs = 60_000L

    // Max gain allowed — capped at 3× when relaying to phone speaker to prevent feedback
    @Volatile var maxAllowedGain = 10.0f

    private var audioManager: AudioManager? = null
    private var previousAudioMode = AudioManager.MODE_NORMAL
    private var audioThread: Thread? = null
    @Volatile private var audioRecord: AudioRecord? = null
    @Volatile private var audioTrack: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null

    // ── IIR filter state ──────────────────────────────────────────────────────

    // High-pass (configurable cutoff)
    private var hpX1 = 0.0; private var hpX2 = 0.0
    private var hpY1 = 0.0; private var hpY2 = 0.0
    private var hpA1 = 0.0; private var hpA2 = 0.0
    private var hpB0 = 0.0; private var hpB1 = 0.0; private var hpB2 = 0.0

    // Low-pass fixed 3.5 kHz — tightened from 8kHz to cut speaker bleed above voice range
    private val lpA1 = -0.2870; private val lpA2 =  0.1872
    private val lpB0 =  0.2247; private val lpB1 =  0.4494; private val lpB2 =  0.2247
    private var lpX1 = 0.0; private var lpX2 = 0.0
    private var lpY1 = 0.0; private var lpY2 = 0.0

    // Bass shelf 250 Hz
    private var bsA1 = 0.0; private var bsA2 = 0.0
    private var bsB0 = 1.0; private var bsB1 = 0.0; private var bsB2 = 0.0
    private var bsX1 = 0.0; private var bsX2 = 0.0
    private var bsY1 = 0.0; private var bsY2 = 0.0

    // Mid peak 1 kHz
    private var mpA1 = 0.0; private var mpA2 = 0.0
    private var mpB0 = 1.0; private var mpB1 = 0.0; private var mpB2 = 0.0
    private var mpX1 = 0.0; private var mpX2 = 0.0
    private var mpY1 = 0.0; private var mpY2 = 0.0

    // Treble shelf 4 kHz
    private var tsA1 = 0.0; private var tsA2 = 0.0
    private var tsB0 = 1.0; private var tsB1 = 0.0; private var tsB2 = 0.0
    private var tsX1 = 0.0; private var tsX2 = 0.0
    private var tsY1 = 0.0; private var tsY2 = 0.0

    // ── Coefficient computation ───────────────────────────────────────────────

    private fun computeHighPass(cutHz: Double) {
        val w = 2 * Math.PI * cutHz / sampleRate
        val k = kotlin.math.tan(w / 2)
        val norm = 1.0 / (1 + sqrt(2.0) * k + k * k)
        hpB0 =  norm; hpB1 = -2 * norm; hpB2 = norm
        hpA1 =  2 * (k * k - 1) * norm
        hpA2 =  (1 - sqrt(2.0) * k + k * k) * norm
    }

    private fun computeBassShelf(gainDb: Double) {
        val A  = 10.0.pow(gainDb / 40.0)
        val w0 = 2 * Math.PI * 250.0 / sampleRate
        val cw = cos(w0); val alpha = sin(w0) / (2 * 0.7071); val sqA = sqrt(A)
        val b0 = A*((A+1)-(A-1)*cw+2*sqA*alpha); val b1 = 2*A*((A-1)-(A+1)*cw)
        val b2 = A*((A+1)-(A-1)*cw-2*sqA*alpha)
        val a0 = (A+1)+(A-1)*cw+2*sqA*alpha; val a1 = -2*((A-1)+(A+1)*cw)
        val a2 = (A+1)+(A-1)*cw-2*sqA*alpha
        bsB0=b0/a0; bsB1=b1/a0; bsB2=b2/a0; bsA1=a1/a0; bsA2=a2/a0
    }

    private fun computeMidPeak(gainDb: Double) {
        val A  = 10.0.pow(gainDb / 40.0)
        val w0 = 2 * Math.PI * 1000.0 / sampleRate
        val alpha = sin(w0) / (2 * 0.8); val cw = cos(w0)
        val b0=1+alpha*A; val b1=-2*cw; val b2=1-alpha*A
        val a0=1+alpha/A; val a1=-2*cw; val a2=1-alpha/A
        mpB0=b0/a0; mpB1=b1/a0; mpB2=b2/a0; mpA1=a1/a0; mpA2=a2/a0
    }

    private fun computeTrebleShelf(gainDb: Double) {
        val A  = 10.0.pow(gainDb / 40.0)
        val w0 = 2 * Math.PI * 4000.0 / sampleRate
        val cw = cos(w0); val alpha = sin(w0) / (2 * 0.7071); val sqA = sqrt(A)
        val b0 = A*((A+1)+(A-1)*cw+2*sqA*alpha); val b1 = -2*A*((A-1)+(A+1)*cw)
        val b2 = A*((A+1)+(A-1)*cw-2*sqA*alpha)
        val a0 = (A+1)-(A-1)*cw+2*sqA*alpha; val a1 = 2*((A-1)-(A+1)*cw)
        val a2 = (A+1)-(A-1)*cw-2*sqA*alpha
        tsB0=b0/a0; tsB1=b1/a0; tsB2=b2/a0; tsA1=a1/a0; tsA2=a2/a0
    }

    private fun recomputeCoefficients() {
        computeHighPass(lowCutHz)
        computeBassShelf(eqBassDb)
        computeMidPeak(eqMidDb)
        computeTrebleShelf(eqTrebleDb)
    }

    private fun resetFilterState() {
        hpX1=0.0; hpX2=0.0; hpY1=0.0; hpY2=0.0
        lpX1=0.0; lpX2=0.0; lpY1=0.0; lpY2=0.0
        bsX1=0.0; bsX2=0.0; bsY1=0.0; bsY2=0.0
        mpX1=0.0; mpX2=0.0; mpY1=0.0; mpY2=0.0
        tsX1=0.0; tsX2=0.0; tsY1=0.0; tsY2=0.0
    }

    // ── Audio processing ──────────────────────────────────────────────────────

    private fun processBuffer(buf: ShortArray, frames: Int, g: Float, limit: Double): Float {
        var peak = 0.0
        for (i in 0 until frames) {
            var x = buf[i].toDouble()

            // High-pass
            val hpY = hpB0*x + hpB1*hpX1 + hpB2*hpX2 - hpA1*hpY1 - hpA2*hpY2
            hpX2=hpX1; hpX1=x; hpY2=hpY1; hpY1=hpY

            // Low-pass
            val lpY = lpB0*hpY + lpB1*lpX1 + lpB2*lpX2 - lpA1*lpY1 - lpA2*lpY2
            lpX2=lpX1; lpX1=hpY; lpY2=lpY1; lpY1=lpY

            // Bass shelf
            val bsY = bsB0*lpY + bsB1*bsX1 + bsB2*bsX2 - bsA1*bsY1 - bsA2*bsY2
            bsX2=bsX1; bsX1=lpY; bsY2=bsY1; bsY1=bsY

            // Mid peak
            val mpY = mpB0*bsY + mpB1*mpX1 + mpB2*mpX2 - mpA1*mpY1 - mpA2*mpY2
            mpX2=mpX1; mpX1=bsY; mpY2=mpY1; mpY1=mpY

            // Treble shelf
            val tsY = tsB0*mpY + tsB1*tsX1 + tsB2*tsX2 - tsA1*tsY1 - tsA2*tsY2
            tsX2=tsX1; tsX1=mpY; tsY2=tsY1; tsY1=tsY

            // Gain + soft limiter
            val scaled = tsY * g
            val out = if (abs(scaled) > limit)
                limit * (if (scaled > 0) 1.0 else -1.0) * (1 - exp(-abs(scaled) / limit) * 0.1)
            else scaled

            val clamped = out.coerceIn(-32767.0, 32767.0)
            buf[i] = clamped.toInt().toShort()
            if (abs(clamped) > peak) peak = abs(clamped)
        }
        return (peak / 32767).toFloat().coerceIn(0f, 1f)
    }

    // ── Service lifecycle ─────────────────────────────────────────────────────

    override fun onBind(intent: Intent): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRelay()
            ACTION_STOP  -> { stopRelay(); stopSelf() }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopRelay()
        super.onDestroy()
    }

    // ── Public control API (called from MainActivity via binder) ──────────────

    fun startRelay() {
        if (isRunning) return
        recomputeCoefficients()
        resetFilterState()

        // Route to earpiece when no external output is connected.
        // Earpiece points away from the mic — drastically reduces acoustic bleed vs loudspeaker.
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        audioManager = am
        previousAudioMode = am.mode
        val isBluetooth = am.isBluetoothA2dpOn
        val isWired     = am.isWiredHeadsetOn
        when {
            isBluetooth -> maxAllowedGain = 6.0f   // BT echo risk — cap limits feedback buildup
            isWired     -> maxAllowedGain = 10.0f  // wired has no echo risk
            else        -> {                        // phone speaker — route to earpiece
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                am.isSpeakerphoneOn = false
                maxAllowedGain = 4.0f
            }
        }

        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            sampleRate, channelIn, encoding, bufferSize,
        )

        if (echoCancelEnabled && AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(record.audioSessionId)
            aec?.enabled = true
        }
        if (noiseSuppressEnabled && NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(record.audioSessionId)
            ns?.enabled = true
        }

        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(encoding)
                .setChannelMask(channelOut)
                .build())
            .setBufferSizeInBytes(bufferSize * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        audioRecord = record
        audioTrack  = track
        isRunning   = true

        record.startRecording()
        track.playbackRate = (sampleRate * pitchRate).toInt().coerceIn(1, sampleRate * 4)
        track.play()
        startForeground(NOTIFICATION_ID, buildNotification())

        audioThread = Thread {
            val buf = ShortArray(bufferSize / 2)
            var silentSince = System.currentTimeMillis()
            var timeoutFired = false
            while (isRunning) {
                val frames = record.read(buf, 0, buf.size)
                if (frames <= 0) continue
                val level = processBuffer(buf, frames, gain, 32767.0 * maxThreshold)
                audioTrack?.write(buf, 0, frames)
                // Silence timeout — signal UI after 60s of near-zero level
                if (level > 0.01f) {
                    silentSince = System.currentTimeMillis()
                    timeoutFired = false
                } else if (!timeoutFired &&
                    System.currentTimeMillis() - silentSince > silenceTimeoutMs) {
                    timeoutFired = true
                    onLevelUpdate?.invoke(-1f) // sentinel: silence timeout
                }
                if (!timeoutFired) onLevelUpdate?.invoke(level)
            }
        }.also { it.start() }
    }

    fun stopRelay() {
        if (!isRunning) return
        isRunning = false
        audioThread?.join(500)
        audioThread = null
        aec?.release(); aec = null
        ns?.release();  ns = null
        audioRecord?.stop(); audioRecord?.release(); audioRecord = null
        audioTrack?.stop(); audioTrack?.release(); audioTrack = null
        resetFilterState()
        // Restore audio routing to what it was before relay started
        audioManager?.let {
            it.isSpeakerphoneOn = false
            it.mode = previousAudioMode
        }
        audioManager = null
        maxAllowedGain = 10.0f
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    fun applySettings(
        newGain: Float, newLowCutHz: Double, newMaxThreshold: Float,
        newBassDb: Double, newMidDb: Double, newTrebleDb: Double,
        newPitchRate: Float = pitchRate,
    ) {
        gain = newGain
        maxThreshold = newMaxThreshold
        if (newLowCutHz != lowCutHz)   { lowCutHz = newLowCutHz;     computeHighPass(lowCutHz) }
        if (newBassDb != eqBassDb)     { eqBassDb = newBassDb;       computeBassShelf(eqBassDb) }
        if (newMidDb != eqMidDb)       { eqMidDb = newMidDb;         computeMidPeak(eqMidDb) }
        if (newTrebleDb != eqTrebleDb) { eqTrebleDb = newTrebleDb;   computeTrebleShelf(eqTrebleDb) }
        if (newPitchRate != pitchRate) {
            pitchRate = newPitchRate
            if (isRunning) restartAudioTrack()
        }
    }

    // Swap out AudioTrack only — AudioRecord keeps running so there's no mic gap.
    // Draining the old buffer then creating a fresh track with the new playback rate
    // gives an instant clean pitch switch instead of a 200-300ms smeared transition.
    private fun restartAudioTrack() {
        val oldTrack = audioTrack
        val newTrack = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(encoding)
                .setChannelMask(channelOut)
                .build())
            .setBufferSizeInBytes(bufferSize * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        newTrack.playbackRate = (sampleRate * pitchRate).toInt().coerceIn(1, sampleRate * 4)
        newTrack.play()
        // Swap visible to audio thread first, then release old — prevents write-to-released-track
        audioTrack = newTrack
        oldTrack?.pause()
        oldTrack?.flush()
        oldTrack?.release()
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID, "Mic Relay", NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "Micify relay is active" }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, MicRelayService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val version = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        } catch (_: Exception) { "" }
        val title = if (version.isNotEmpty()) "Micify $version · Relay active" else "Micify — Relay active"
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText("Tap to open app  •  Swipe down for Stop button")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_delete, "⏹ Stop relay", stopIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        const val ACTION_START   = "com.vel.micify.START"
        const val ACTION_STOP    = "com.vel.micify.STOP"
        const val CHANNEL_ID     = "micify_relay"
        const val NOTIFICATION_ID = 1
    }
}
