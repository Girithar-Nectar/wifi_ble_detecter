package com.example.attendance_tracker

import android.app.Activity
import android.content.Intent
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.os.Build
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject

/**
 * Invisible activity for `attendancetracker://checkpoint` from an NFC tag or a
 * QR code opened by the camera. It works even when the app is killed: the raw
 * checkpoint is queued natively, tracking is started, and the app is brought
 * up so Dart can verify the checkpoint.
 */
class CheckpointActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
        finish()
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        val raw = JSONObject().put("timestamp", System.currentTimeMillis())
        val payloads = JSONArray()

        if (intent.action == NfcAdapter.ACTION_NDEF_DISCOVERED) {
            raw.put("source", "nfc")
            tag(intent)?.id?.let { raw.put("uid", NfcReader.toHex(it)) }
            ndefMessages(intent).flatMap(NfcReader::parseMessage).forEach { payloads.put(it) }
        } else {
            raw.put("source", "qr")
        }
        if (payloads.length() == 0) intent.dataString?.let { payloads.put(it) }
        if (payloads.length() == 0 && !raw.has("uid")) return
        raw.put("payloads", payloads)

        NativeStore.addPendingCheckpoint(this, raw)
        if (NativeStore.isTrackingEnabled(this)) {
            // Allowed here: this activity is visible.
            ServiceStarter.ensureRunning(this)
        }
        AttendanceTrackerPlugin.broadcast("onPendingCheckpoint", null)

        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            startActivity(launch)
        }
    }

    private fun tag(intent: Intent): Tag? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG)
        }

    private fun ndefMessages(intent: Intent): List<NdefMessage> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES, NdefMessage::class.java)?.toList()
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)?.filterIsInstance<NdefMessage>()
        } ?: emptyList()
}
