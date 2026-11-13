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
    // AGP 9 with Gradle 9.8.1 (gradle/wrapper): Gradle 9 is needed to run on current JDKs (Android
    // Studio bundles JDK 25). Gradle 9 removed `Project.exec()` and `Project.buildDir`, so the
    // vendored Cargokit plugin (rust_builder/cargokit/gradle/plugin.gradle) was ported to
    // ExecOperations and `layout.buildDirectory`. AGP 9's legacy variant API, which Cargokit and
    // Flutter still use, stays available while gradle.properties keeps `android.newDsl=false`.
    id("com.android.application") version "9.4.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
}

include(":app")
