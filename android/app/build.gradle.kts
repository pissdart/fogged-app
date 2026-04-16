import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("app/key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.fogged.orcax"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.fogged.vpn"
        minSdk = 26 // Android 8.0+ (for VpnService + foreground service)
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Ship arm64-v8a only. Covers every phone from ~2019+. Keeping a
        // single ABI cuts APK size dramatically and avoids crashes on
        // legacy armv7 devices where we don't have native binaries.
        ndk {
            abiFilters.add("arm64-v8a")
        }
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
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 minification + resource shrinking. Cuts APK size ~40% and
            // strips symbols so the release build isn't trivially reversible.
            // Proguard rules tuned below to keep VPN classes & kotlinx metadata.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packaging {
        // Prebuilt native binaries (xray, hysteria, tun2socks, vk-turn-client).
        // Don't strip debug info from these — they are upstream binaries, not
        // our own code, and stripping can break them.
        jniLibs.keepDebugSymbols.add("**/lib*.so")
    }
}

flutter {
    source = "../.."
}
