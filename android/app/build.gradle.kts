import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Release signing config from android/key.properties (gitignored — keystore +
// passwords never enter version control). Absent on a fresh checkout / CI, in
// which case the release build falls back to debug signing so `flutter run
// --release` still works without the secrets.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

android {
    namespace = "cc.imagineering.aiko_chat_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cc.imagineering.aiko_chat_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 27 (Android 8.1), not Flutter's default 24. The incoming-call screen
        // needs setShowWhenLocked/setTurnScreenOn (27) and
        // requestDismissKeyguard (26); below that, each was a fallback branch
        // nobody can test, and one of them answered — camera on — while the
        // phone was still LOCKED (cage-match PR #210 v2 round 1). Dropping the
        // OS removes the branches instead of guarding them. Nick, 2026-10-06:
        // "Below Android 8? come on, we're not handling that case".
        minSdk = 27
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Real upload-key signing when key.properties is present; debug
            // fallback otherwise so `flutter run --release` works on a fresh tree.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // AikoMessagingService extends the firebase_messaging plugin's service,
    // whose supertype lives in `firebase-messaging` — which the plugin declares
    // `implementation`, so it is on the plugin's classpath and not ours.
    //
    // COMPILE-ONLY, so this never chooses the runtime version: the plugin's
    // BoM still does, and a firebase_core upgrade cannot leave two versions of
    // the SDK fighting in one APK. The pin below only has to carry the two
    // members we touch (`onMessageReceived`, `RemoteMessage.getData`), stable
    // since the v1 API. 34.17.0 = firebase_core 4.13.0's `FirebaseSDKVersion`.
    compileOnly(platform("com.google.firebase:firebase-bom:34.17.0"))
    compileOnly("com.google.firebase:firebase-messaging")
}
