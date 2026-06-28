import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: load android/key.properties if present — created locally once
// (via keytool) or materialized in CI from repo secrets. When absent we fall back
// to the debug key so dev `flutter run --release` still works WITHOUT a keystore;
// but a debug-signed release can't install over a properly-signed one (different
// signature → "软件包冲突"), and CI's debug key differs every run, so real
// releases must carry this keystore.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKeystore) FileInputStream(keystorePropertiesFile).use { load(it) }
}

android {
    namespace = "dev.cchandoff.app"
    // Pinned to 36 (not flutter.compileSdkVersion, currently 34): a transitive
    // dep (flutter_plugin_android_lifecycle) now requires consumers to compile
    // against API 36. Plugin subprojects are bumped to match in the root
    // build.gradle.kts.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.cchandoff.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the release keystore when present (key.properties), else
            // the debug key (dev convenience — see the note at the top of file).
            signingConfig = signingConfigs.getByName(
                if (hasReleaseKeystore) "release" else "debug",
            )
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
