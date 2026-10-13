package com.example.attendance_tracker

import android.app.Activity
import android.content.Context
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset

/** Reads one tag in reader mode while the app is in the foreground. */
internal class NfcReader(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var activity: Activity? = null
    private var timeout: Runnable? = null

    fun isAvailable(): Boolean = NfcAdapter.getDefaultAdapter(context)?.isEnabled == true

    fun start(activity: Activity?, timeoutMs: Long, result: MethodChannel.Result) {
        val adapter = NfcAdapter.getDefaultAdapter(context)
        if (adapter == null) {
            result.error("NFC_UNAVAILABLE", "This device has no NFC reader.", null)
            return
        }
        if (!adapter.isEnabled) {
            result.error("NFC_DISABLED", "NFC is turned off. Turn it on in Settings.", null)
            return
        }
        if (activity == null) {
            result.error("NO_ACTIVITY", "NFC reading needs the app on screen.", null)
            return
        }
        finishError("CANCELLED", "Replaced by a new NFC scan.")

        pending = result
        this.activity = activity
        val flags = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or NfcAdapter.FLAG_READER_NFC_V
        val extras = Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250) }
        try {
            adapter.enableReaderMode(activity, { tag -> onTag(tag) }, flags, extras)
        } catch (e: Exception) {
            finishError("NFC_ERROR", "Could not start NFC: ${e.message}")
            return
        }
        timeout = Runnable { finishError("TIMEOUT", "No NFC tag was detected.") }.also {
            handler.postDelayed(it, timeoutMs)
        }
    }

    fun stop() = finishError("CANCELLED", "NFC scan cancelled.")

    /** Called on a binder thread. */
    private fun onTag(tag: Tag) {
        val uid = tag.id?.let(::toHex)
        val payloads = mutableListOf<String>()
        Ndef.get(tag)?.let { ndef ->
            try {
                ndef.connect()
                (ndef.ndefMessage ?: ndef.cachedNdefMessage)?.let { payloads += parseMessage(it) }
            } catch (_: Exception) {
                ndef.cachedNdefMessage?.let { payloads += parseMessage(it) }
            } finally {
                runCatching { ndef.close() }
            }
        }
        handler.post {
            val result = pending ?: return@post
            pending = null
            cleanup()
            result.success(mapOf("uid" to uid, "payloads" to payloads))
        }
    }

    private fun finishError(code: String, message: String) {
        val result = pending ?: return
        pending = null
        cleanup()
        result.error(code, message, null)
    }

    private fun cleanup() {
        timeout?.let(handler::removeCallbacks)
        timeout = null
        activity?.let { runCatching { NfcAdapter.getDefaultAdapter(context)?.disableReaderMode(it) } }
        activity = null
    }

    companion object {
        fun toHex(bytes: ByteArray): String = bytes.joinToString(":") { "%02X".format(it) }

        fun parseMessage(message: NdefMessage): List<String> = message.records.mapNotNull(::parseRecord)

        /** Text, URI and text-like MIME/external records as strings. */
        fun parseRecord(record: NdefRecord): String? = try {
            when {
                record.tnf == NdefRecord.TNF_WELL_KNOWN && record.type.contentEquals(NdefRecord.RTD_TEXT) -> {
                    val payload = record.payload
                    val status = payload[0].toInt()
                    val languageLength = status and 0x3F
                    val charset = if (status and 0x80 != 0) Charsets.UTF_16 else Charsets.UTF_8
                    String(payload, 1 + languageLength, payload.size - 1 - languageLength, charset)
                }
                record.toUri() != null -> record.toUri().toString()
                record.tnf == NdefRecord.TNF_MIME_MEDIA && String(record.type, Charsets.US_ASCII).startsWith("text/") ->
                    String(record.payload, Charset.forName("UTF-8"))
                record.tnf == NdefRecord.TNF_EXTERNAL_TYPE -> String(record.payload, Charsets.UTF_8)
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }
}
