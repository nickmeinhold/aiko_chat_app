pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // Reads android/app/google-services.json at build time and generates the FCM
    // sender id into resources. ANDROID ONLY — there is deliberately no iOS
    // counterpart and no GoogleService-Info.plist; Apple platforms take their
    // APNs token natively (claude-tasks#3267).
    id("com.google.gms.google-services") version "4.4.3" apply false
}

include(":app")
