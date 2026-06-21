package com.vel.micify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager

class PhoneStateReceiver(
    private val onCallStarted: () -> Unit,
    private val onCallEnded: () -> Unit,
) : BroadcastReceiver() {

    private var wasRinging = false

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
            TelephonyManager.EXTRA_STATE_RINGING,
            TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                wasRinging = true
                onCallStarted()
            }
            TelephonyManager.EXTRA_STATE_IDLE -> {
                if (wasRinging) {
                    wasRinging = false
                    onCallEnded()
                }
            }
        }
    }
}
