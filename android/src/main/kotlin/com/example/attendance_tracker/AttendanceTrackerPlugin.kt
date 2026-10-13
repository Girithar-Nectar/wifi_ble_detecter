package com.example.attendance_tracker

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import android.app.Activity
import org.json.JSONObject

/** AttendanceTrackerPlugin */
class AttendanceTrackerPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware {
    // The MethodChannel that will the communication between Flutter and native Android
    //
    // This local reference serves to register the plugin with the Flutter Engine and unregister it
    // when the Flutter Engine is detached from the Activity
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var nfcReader: NfcReader? = null

    companion object {
        // One channel per engine: the UI engine and the background service engine.
        private val channels = mutableSetOf<MethodChannel>()
        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        private var attachedActivities = 0

        /** Calls [method] on every attached Dart side, e.g. to wake the service isolate. */
        fun broadcast(method: String, arguments: Any?) {
            mainHandler.post {
                synchronized(channels) { channels.toList() }.forEach { it.invokeMethod(method, arguments) }
            }
        }

        /** foreground: UI visible; background: UI alive but hidden; terminated: no UI (service only). */
        fun appState(): String {
            val info = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(info)
            return when {
                info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "foreground"
                attachedActivities > 0 -> "background"
                else -> "terminated"
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "attendance_tracker")
        channel.setMethodCallHandler(this)
        synchronized(channels) { channels.add(channel) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        synchronized(channels) { channels.remove(channel) }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        attachedActivities++
    }

    override fun onDetachedFromActivityForConfigChanges() {
        nfcReader?.stop()
        activity = null
        attachedActivities--
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        attachedActivities++
    }

    override fun onDetachedFromActivity() {
        nfcReader?.stop()
        activity = null
        attachedActivities--
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            "getAndroidSdkInt" -> {
                result.success(android.os.Build.VERSION.SDK_INT)
            }
            "isWifiEnabled" -> {
                val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                result.success(wifiManager.isWifiEnabled)
            }
            "setWifiEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

                // Note: On Android 10 (API 29) and higher, this will always return false for non-system apps
                @Suppress("DEPRECATION")
                val success = wifiManager.setWifiEnabled(enabled)
                result.success(success)
            }
            "openWifiSettings" -> {
                val intent = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    Intent(Settings.Panel.ACTION_WIFI)
                } else {
                    Intent(Settings.ACTION_WIFI_SETTINGS)
                }
                startActivity(intent)
                result.success(true)
            }
            "configure" -> {
                val config = call.argument<Map<*, *>>("config") ?: emptyMap<String, Any?>()
                NativeStore.setConfig(context, Json.toJson(config))
                if (NativeStore.isTrackingEnabled(context)) GeofenceManager.register(context)
                result.success(null)
            }
            "setTrackingEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                NativeStore.setTrackingEnabled(context, enabled)
                if (enabled) {
                    GeofenceManager.register(context)
                } else {
                    GeofenceManager.unregister(context)
                    // Next start re-detects presence and emits a fresh enter.
                    NativeStore.resetZoneState(context)
                }
                result.success(null)
            }
            "getZoneState" -> result.success(NativeStore.getZoneState(context))
            "resetZoneState" -> {
                NativeStore.resetZoneState(context)
                result.success(null)
            }
            "setZoneState" -> {
                NativeStore.setZoneState(
                    context,
                    call.argument<Boolean>("wasInZone") ?: false,
                    call.argument<Int>("failCount") ?: 0,
                )
                result.success(null)
            }
            "isTrackingEnabled" -> result.success(NativeStore.isTrackingEnabled(context))
            "refreshMonitoring" -> {
                if (NativeStore.isTrackingEnabled(context)) GeofenceManager.register(context)
                result.success(null)
            }
            // Android scans in the Dart background service; iOS scans natively.
            "scanNow" -> result.success(null)
            "appendEvent" -> {
                val event = Json.toJson(call.argument<Map<*, *>>("event") ?: emptyMap<String, Any?>())
                if (event.isNull("appState")) event.put("appState", appState())
                NativeStore.appendEvent(context, event)
                result.success(null)
            }
            "getEvents" -> {
                val pendingOnly = call.argument<Boolean>("pendingOnly") ?: true
                result.success(NativeStore.getEvents(context, pendingOnly).map(Json::toMap))
            }
            "acknowledgeEvents" -> {
                NativeStore.acknowledgeEvents(context, call.argument<List<String>>("ids").orEmpty().toSet())
                result.success(null)
            }
            "markEventsUploaded" -> {
                NativeStore.markEventsUploaded(context, call.argument<List<String>>("ids").orEmpty().toSet())
                result.success(null)
            }
            "recordCheckpoint" -> {
                result.success(recordCheckpoint(Json.toJson(call.argument<Map<*, *>>("checkpoint") ?: emptyMap<String, Any?>())))
            }
            "getLastCheckpoint" -> result.success(NativeStore.getLastCheckpoint(context)?.let(Json::toMap))
            "takePendingCheckpoints" -> result.success(NativeStore.takePendingCheckpoints(context).map(Json::toMap))
            "saveLastResult" -> {
                NativeStore.saveLastResult(context, Json.toJson(call.argument<Map<*, *>>("result") ?: emptyMap<String, Any?>()))
                result.success(null)
            }
            "getLastResult" -> result.success(NativeStore.getLastResult(context)?.let(Json::toMap))
            "isNfcAvailable" -> result.success(nfc().isAvailable())
            "readNfcTag" -> {
                val timeout = (call.argument<Number>("timeoutMs") ?: 30000).toLong()
                nfc().start(activity, timeout, result)
            }
            "stopNfcSession" -> {
                nfcReader?.stop()
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
            "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())
            "testNotification" -> result.success(null)
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun nfc(): NfcReader = nfcReader ?: NfcReader(context).also { nfcReader = it }

    /**
     * Stores the verified checkpoint and logs it as an event; the Dart service
     * evaluates the zone. With checkpointToggle, a tap while in zone is a
     * tap-out: the exit is recorded here at once.
     */
    private fun recordCheckpoint(checkpoint: JSONObject): Map<String, Any?> {
        val timestamp = checkpoint.optLong("timestamp", System.currentTimeMillis())
        checkpoint.put("timestamp", timestamp)
        val source = checkpoint.optString("source")
        val toggle = NativeStore.getConfig(context)?.optBoolean("checkpointToggle", false) == true
        val tapOut = toggle && NativeStore.getZoneState(context)["wasInZone"] == true

        if (tapOut) {
            NativeStore.tapOut(context, timestamp)
        } else {
            NativeStore.setLastCheckpoint(context, checkpoint)
        }
        val type = if (tapOut) "exit" else "checkpoint"
        val event = JSONObject()
            .put("id", "${timestamp * 1000}-$type")
            .put("type", type)
            .put("source", source)
            .put("trigger", source)
            .put("appState", appState())
            .put("timestamp", timestamp)
            .put("checkpointId", checkpoint.opt("checkpointId"))
            .put("uploaded", false)
        NativeStore.appendEvent(context, event)
        broadcast("onEvent", Json.toMap(event))
        return mapOf("tapOut" to tapOut)
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Shows the direct "allow" prompt when the host declares
     * REQUEST_IGNORE_BATTERY_OPTIMIZATIONS (a Play policy decision left to the
     * host), otherwise the battery optimisation settings list.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        val intent = if (declaresPermission(Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)) {
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
        } else {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        }
        return try {
            startActivity(intent)
            false
        } catch (_: Exception) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun declaresPermission(permission: String): Boolean = try {
        context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.contains(permission) == true
    } catch (_: Exception) {
        false
    }

    private fun startActivity(intent: Intent) {
        val currentActivity = activity
        if (currentActivity != null) {
            currentActivity.startActivity(intent)
        } else {
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            context.startActivity(intent)
        }
    }
}
