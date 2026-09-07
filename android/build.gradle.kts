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
    // Workmanager assumes AGP 9's built-in Kotlin, which this project opts out of.
    if (name == "workmanager_android" &&
        providers.gradleProperty("android.builtInKotlin").orNull == "false") {
        plugins.withId("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
            extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
            }
        }
    }
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
