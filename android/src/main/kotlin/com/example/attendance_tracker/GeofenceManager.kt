package com.example.attendance_tracker

import android.Manifest
import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

private const val TAG = "AttendanceTracker"

/**
 * Registers the office points as Play Services geofences. Unlike the Dart
 * timer, geofences keep working after the app is swiped away, and their
 * broadcast is one of the cases where Android 12+ lets an app start a
 * foreground service from the background.
 */
internal object GeofenceManager {
    private const val REQUEST_CODE = 7301
    private const val MAX_GEOFENCES = 90
    private const val MIN_RADIUS_METERS = 100f
    const val ACTION_GEOFENCE = "com.example.attendance_tracker.ACTION_GEOFENCE"

    fun register(context: Context) {
        val config = NativeStore.getConfig(context) ?: return
        val points = officePoints(config.optJSONArray("officePoints"))
        if (points.isEmpty()) {
            unregister(context)
            return
        }
        if (!hasFineLocation(context)) {
            Log.w(TAG, "Geofences skipped: location permission not granted")
            return
        }
        val radius = maxOf(config.optDouble("geofenceRadius", 100.0).toFloat(), MIN_RADIUS_METERS)
        val geofences = points.take(MAX_GEOFENCES).mapIndexed { index, (lat, lng) ->
            Geofence.Builder()
                .setRequestId("attendance_tracker_$index")
                .setCircularRegion(lat, lng, radius)
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
                .build()
        }
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofences(geofences)
            .build()

        val client = LocationServices.getGeofencingClient(context)
        val intent = pendingIntent(context)
        client.removeGeofences(intent).addOnCompleteListener {
            addGeofences(context, request, intent)
        }
    }

    fun unregister(context: Context) {
        LocationServices.getGeofencingClient(context).removeGeofences(pendingIntent(context))
    }

    @SuppressLint("MissingPermission")
    private fun addGeofences(context: Context, request: GeofencingRequest, intent: PendingIntent) {
        try {
            LocationServices.getGeofencingClient(context).addGeofences(request, intent)
                .addOnSuccessListener { Log.i(TAG, "Registered ${request.geofences.size} geofences") }
                .addOnFailureListener {
                    // 1004 = background location ("Allow all the time") not granted.
                    Log.w(TAG, "Geofence registration failed: ${it.message}")
                }
        } catch (e: SecurityException) {
            Log.w(TAG, "Geofence registration needs location permission: ${e.message}")
        }
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, GeofenceReceiver::class.java).setAction(ACTION_GEOFENCE)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        // Play Services fills in the transition, so the intent must stay mutable.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }

    private fun hasFineLocation(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** Parses WKT "POINT(lng lat)" entries into (lat, lng) pairs. */
    private fun officePoints(array: org.json.JSONArray?): List<Pair<Double, Double>> {
        if (array == null) return emptyList()
        val regex = Regex("""POINT\s*\(\s*(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s*\)""", RegexOption.IGNORE_CASE)
        return (0 until array.length()).mapNotNull { index ->
            val match = regex.find(array.optString(index)) ?: return@mapNotNull null
            val lng = match.groupValues[1].toDoubleOrNull() ?: return@mapNotNull null
            val lat = match.groupValues[2].toDoubleOrNull() ?: return@mapNotNull null
            lat to lng
        }
    }
}

/** Wakes tracking on a geofence transition, restarting the service if it was killed. */
class GeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!NativeStore.isTrackingEnabled(context)) return
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            Log.w(TAG, "Geofence error ${event.errorCode}")
            return
        }
        val transition = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "enter"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "exit"
            else -> "dwell"
        }
        Log.i(TAG, "Geofence $transition")
        ServiceStarter.ensureRunning(context)
        AttendanceTrackerPlugin.broadcast("onWake", mapOf("trigger" to "geofence", "transition" to transition))
    }
}

/** Geofences are cleared on reboot; register them again. */
class RestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!NativeStore.isTrackingEnabled(context)) return
        Log.i(TAG, "Re-registering geofences after ${intent.action}")
        GeofenceManager.register(context)
    }
}

/** Starts flutter_background_service's service, which runs the Dart detection loop. */
internal object ServiceStarter {
    private const val SERVICE_CLASS = "id.flutter.flutter_background_service.BackgroundService"

    fun ensureRunning(context: Context) {
        if (isRunning(context)) return
        val intent = Intent().setClassName(context.packageName, SERVICE_CLASS)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            // Android 12+ refuses background starts without an exemption
            // (geofence event, visible activity, battery optimisation off).
            Log.w(TAG, "Could not start tracking service: ${e.message}")
        }
    }

    @Suppress("DEPRECATION")
    private fun isRunning(context: Context): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return manager.getRunningServices(Int.MAX_VALUE).any { it.service.className == SERVICE_CLASS }
    }
}
