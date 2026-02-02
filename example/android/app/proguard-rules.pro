-keep class co.altme.alt.me.altme.** { *; }
-keep class it.airgap.beaconsdk.** { *; }
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class com.lib.flutter_blue_plus.* { *; }

# Flutter Background Service
-keep class id.flutter.flutter_background_service.** { *; }
-keep public class id.flutter.flutter_background_service.BackgroundService { *; }
-keep public class id.flutter.flutter_background_service.BootReceiver { *; }

# Flutter Local Notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver { *; }
-keep class com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver { *; }
-keep class com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver { *; }

# Attendance Tracker Plugin
-keep class com.example.attendance_tracker.** { *; }
-keep class com.example.attendance_tracker.AttendanceTrackerPlugin { *; }

# Standard Keep Rules
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault,SourceFile,LineNumberTable
-keep public class * extends android.app.Activity
-keep public class * extends android.app.Application
-keep public class * extends android.app.Service
-keep public class * extends android.content.BroadcastReceiver
-keep public class * extends android.content.ContentProvider