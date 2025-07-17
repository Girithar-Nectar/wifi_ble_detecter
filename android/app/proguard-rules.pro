-keep class co.altme.alt.me.altme.** { *; }
-keep class it.airgap.beaconsdk.** { *; }
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class com.lib.flutter_blue_plus.* { *; }





# @Serializable and @Polymorphic are used at runtime for polymorphic serialization.
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault