allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some plugins still pin an old compileSdk (file_picker 8.x pins 34), but their own dependencies
// declare a higher minimum that AGP enforces in check<Variant>AarMetadata
// (flutter_plugin_android_lifecycle 2.0.35 requires 36). Raise any lower plugin compileSdk to
// Flutter's default, 36. This only changes the SDK the plugin code compiles against; the app's
// minSdk and targetSdk are unaffected. Registered before evaluationDependsOn(":app") below, which
// evaluates projects early.
subprojects {
    afterEvaluate {
        extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.let { lib ->
            if ((lib.compileSdk ?: 0) < 36) lib.compileSdk = 36
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
