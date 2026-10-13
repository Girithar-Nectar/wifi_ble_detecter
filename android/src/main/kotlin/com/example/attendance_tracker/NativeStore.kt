package com.example.attendance_tracker

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Process-wide store shared by the UI engine, the background service engine and
 * the native receivers, so events and checkpoints survive while Dart is not running.
 */
internal object NativeStore {
    private const val PREFS = "attendance_tracker_native"
    private const val KEY_CONFIG = "config"
    private const val KEY_ENABLED = "tracking_enabled"
    private const val KEY_EVENTS = "events"
    private const val KEY_LAST_CHECKPOINT = "last_checkpoint"
    private const val KEY_PENDING = "pending_checkpoints"
    private const val KEY_LAST_RESULT = "last_result"
    private const val KEY_WAS_IN_ZONE = "was_in_zone"
    private const val KEY_FAIL_COUNT = "fail_count"
    private const val KEY_TAP_OUT_AT = "tap_out_at"
    private const val MAX_EVENTS = 500
    private const val MAX_PENDING = 20

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun setConfig(context: Context, config: JSONObject) {
        prefs(context).edit().putString(KEY_CONFIG, config.toString()).apply()
    }

    @Synchronized
    fun getConfig(context: Context): JSONObject? =
        prefs(context).getString(KEY_CONFIG, null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    @Synchronized
    fun setTrackingEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    @Synchronized
    fun isTrackingEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    @Synchronized
    fun appendEvent(context: Context, event: JSONObject) {
        val events = readArray(context, KEY_EVENTS)
        events.put(event)
        writeArray(context, KEY_EVENTS, trim(events))
    }

    @Synchronized
    fun getEvents(context: Context, pendingOnly: Boolean): List<JSONObject> =
        objects(readArray(context, KEY_EVENTS)).filter { !pendingOnly || !it.optBoolean("acknowledged") }

    /** Host app has synced these; dropped once uploaded too (or when there is no endpoint). */
    @Synchronized
    fun acknowledgeEvents(context: Context, ids: Set<String>) {
        updateEvents(context, ids) { it.put("acknowledged", true) }
    }

    @Synchronized
    fun markEventsUploaded(context: Context, ids: Set<String>) {
        updateEvents(context, ids) { it.put("uploaded", true) }
    }

    /** Confirmed zone state behind enter/exit events, shared by the UI and service engines. */
    @Synchronized
    fun getZoneState(context: Context): Map<String, Any?> {
        val prefs = prefs(context)
        return mapOf(
            "wasInZone" to prefs.getBoolean(KEY_WAS_IN_ZONE, false),
            "failCount" to prefs.getInt(KEY_FAIL_COUNT, 0),
            "tapOutAt" to if (prefs.contains(KEY_TAP_OUT_AT)) prefs.getLong(KEY_TAP_OUT_AT, 0) else null,
        )
    }

    @Synchronized
    fun setZoneState(context: Context, wasInZone: Boolean, failCount: Int) {
        prefs(context).edit().putBoolean(KEY_WAS_IN_ZONE, wasInZone).putInt(KEY_FAIL_COUNT, failCount).apply()
    }

    /** NFC/QR tap-out: out of zone now, checkpoint presence ended. */
    @Synchronized
    fun tapOut(context: Context, at: Long) {
        prefs(context).edit()
            .putBoolean(KEY_WAS_IN_ZONE, false)
            .putInt(KEY_FAIL_COUNT, 0)
            .putLong(KEY_TAP_OUT_AT, at)
            .remove(KEY_LAST_CHECKPOINT)
            .apply()
    }

    @Synchronized
    fun resetZoneState(context: Context) {
        prefs(context).edit()
            .remove(KEY_WAS_IN_ZONE)
            .remove(KEY_FAIL_COUNT)
            .remove(KEY_TAP_OUT_AT)
            .remove(KEY_LAST_CHECKPOINT)
            .apply()
    }

    @Synchronized
    fun setLastCheckpoint(context: Context, checkpoint: JSONObject) {
        prefs(context).edit().putString(KEY_LAST_CHECKPOINT, checkpoint.toString()).apply()
    }

    @Synchronized
    fun getLastCheckpoint(context: Context): JSONObject? =
        prefs(context).getString(KEY_LAST_CHECKPOINT, null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    @Synchronized
    fun addPendingCheckpoint(context: Context, raw: JSONObject) {
        val pending = readArray(context, KEY_PENDING)
        pending.put(raw)
        val list = objects(pending).takeLast(MAX_PENDING)
        writeArray(context, KEY_PENDING, JSONArray(list))
    }

    /** Returns and clears the raw checkpoints, so only one engine processes each. */
    @Synchronized
    fun takePendingCheckpoints(context: Context): List<JSONObject> {
        val list = objects(readArray(context, KEY_PENDING))
        prefs(context).edit().remove(KEY_PENDING).apply()
        return list
    }

    @Synchronized
    fun saveLastResult(context: Context, result: JSONObject) {
        prefs(context).edit().putString(KEY_LAST_RESULT, result.toString()).apply()
    }

    @Synchronized
    fun getLastResult(context: Context): JSONObject? =
        prefs(context).getString(KEY_LAST_RESULT, null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    private fun updateEvents(context: Context, ids: Set<String>, change: (JSONObject) -> Unit) {
        val config = getConfig(context)
        val hasEndpoint = config != null && !config.isNull("apiEndpoint") && config.optString("apiEndpoint").isNotBlank()
        val kept = objects(readArray(context, KEY_EVENTS)).filter { event ->
            if (event.optString("id") in ids) change(event)
            val done = event.optBoolean("acknowledged") && (event.optBoolean("uploaded") || !hasEndpoint)
            !done
        }
        writeArray(context, KEY_EVENTS, JSONArray(kept))
    }

    /** Keeps the newest events; ones already acknowledged go first. */
    private fun trim(events: JSONArray): JSONArray {
        if (events.length() <= MAX_EVENTS) return events
        val list = objects(events).toMutableList()
        while (list.size > MAX_EVENTS) {
            val index = list.indexOfFirst { it.optBoolean("acknowledged") }
            list.removeAt(if (index >= 0) index else 0)
        }
        return JSONArray(list)
    }

    private fun readArray(context: Context, key: String): JSONArray =
        prefs(context).getString(key, null)?.let { runCatching { JSONArray(it) }.getOrNull() } ?: JSONArray()

    private fun writeArray(context: Context, key: String, array: JSONArray) {
        prefs(context).edit().putString(key, array.toString()).apply()
    }

    private fun objects(array: JSONArray): List<JSONObject> =
        (0 until array.length()).mapNotNull { array.optJSONObject(it) }
}

/** Conversions between org.json and the standard method channel codec types. */
internal object Json {
    fun toMap(json: JSONObject): Map<String, Any?> =
        json.keys().asSequence().associateWith { fromJson(json.opt(it)) }

    fun toJson(map: Map<*, *>): JSONObject {
        val json = JSONObject()
        map.forEach { (key, value) -> json.put(key.toString(), toJsonValue(value)) }
        return json
    }

    private fun fromJson(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> toMap(value)
        is JSONArray -> (0 until value.length()).map { fromJson(value.opt(it)) }
        else -> value
    }

    private fun toJsonValue(value: Any?): Any? = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> toJson(value)
        is List<*> -> JSONArray().also { array -> value.forEach { array.put(toJsonValue(it)) } }
        else -> value
    }
}
