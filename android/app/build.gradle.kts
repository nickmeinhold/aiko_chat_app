import java.io.FileInputStream
import java.util.Base64
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

// Flutter hands Gradle every define — `--dart-define` and
// `--dart-define-from-file` alike — as `-Pdart-defines=<b64>,<b64>,…`, each
// entry base64("KEY=value"). `bool.fromEnvironment` is true only for the exact
// string "true", so this is too.
fun callingEnabled(): Boolean {
    val encoded = project.findProperty("dart-defines")?.toString() ?: return false
    return encoded.split(",").any {
        String(Base64.getDecoder().decode(it)) == "ENABLE_CALLING=true"
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
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The native half of `kCallingEnabled` (lib/app/feature_flags.dart),
        // read from the SAME `--dart-define` at compile time. The ring is
        // drawn by Kotlin before any Dart runs, so it cannot ask Dart whether
        // calling is on; a runtime handshake would be a second source of truth
        // that a cold push beats to the punch. One flag, read twice, at build
        // time: the two halves cannot disagree.
        buildConfigField("boolean", "CALLING_ENABLED", callingEnabled().toString())
    }

    buildFeatures {
        buildConfig = true
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
