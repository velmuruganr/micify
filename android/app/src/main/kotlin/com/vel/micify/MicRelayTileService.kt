package com.vel.micify

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class MicRelayTileService : TileService() {

    private var relayService: MicRelayService? = null
    private var serviceBound = false

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            relayService = (binder as MicRelayService.LocalBinder).getService()
            serviceBound = true
            updateTile()
        }
        override fun onServiceDisconnected(name: ComponentName) {
            relayService = null
            serviceBound = false
            updateTile()
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        bindService(
            Intent(this, MicRelayService::class.java),
            connection,
            Context.BIND_AUTO_CREATE,
        )
    }

    override fun onStopListening() {
        super.onStopListening()
        if (serviceBound) {
            unbindService(connection)
            serviceBound = false
            relayService = null
        }
    }

    override fun onClick() {
        super.onClick()
        val svc = relayService
        if (svc != null && svc.isRunning) {
            // Stop relay
            val stopIntent = Intent(this, MicRelayService::class.java).apply {
                action = MicRelayService.ACTION_STOP
            }
            startService(stopIntent)
        } else {
            // Open app — let user start from the UI (mic permission flow needed)
            val openIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            startActivityAndCollapse(openIntent)
        }
        updateTile()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val running = relayService?.isRunning == true
        tile.state = if (running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Micify"
        tile.contentDescription = if (running) "Relay active — tap to stop" else "Tap to open Micify"
        tile.updateTile()
    }
}
