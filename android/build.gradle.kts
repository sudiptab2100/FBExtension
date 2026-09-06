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
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (e.g. flutter_secure_storage, permission_handler_android) declare
// compileSdk 37, which makes Flutter bump every module to 37. Only the preview
// `android-37.0` platform is available on some machines, so Gradle fails to find
// the `android-37` target. Pin the plugin Android modules to the installed stable
// `android-36`. (`:app` is pinned directly in app/build.gradle.kts, and is skipped
// here because evaluationDependsOn(":app") above already evaluated it.)
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            val androidExt = extensions.findByName("android")
            if (androidExt is com.android.build.gradle.BaseExtension) {
                androidExt.compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
