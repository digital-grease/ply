plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.digitalgrease.ply"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.digitalgrease.ply"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // The release signing config is supplied through ENVIRONMENT VARIABLES (set by CI from
            // repository secrets, or by the developer locally). Nothing sensitive is stored in the
            // repo. When the variables are absent, the release build falls back to debug signing
            // below so contributor builds and `flutter run --release` still succeed.
            val storePath = System.getenv("PLY_KEYSTORE_PATH")
            if (!storePath.isNullOrEmpty()) {
                storeFile = file(storePath)
                storePassword = System.getenv("PLY_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("PLY_KEY_ALIAS")
                keyPassword = System.getenv("PLY_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (!System.getenv("PLY_KEYSTORE_PATH").isNullOrEmpty()) {
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
