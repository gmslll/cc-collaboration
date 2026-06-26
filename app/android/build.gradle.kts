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

// Bump every Android subproject (Flutter plugins) to compileSdk 36. Several
// plugins (file_picker, pasteboard, share_plus, …) hard-code compileSdk 34 in
// their own build.gradle, but a transitive dep (flutter_plugin_android_lifecycle)
// now requires consumers to compile against API 36, which fails the AAR-metadata
// check. This overrides their pinned value once each is evaluated; reflection
// keeps it independent of the AGP DSL version. :app is already evaluated here
// (evaluationDependsOn above) and pinned to 36 directly, so configure it inline
// rather than via afterEvaluate (which would throw on an evaluated project).
subprojects {
    val bumpCompileSdk: () -> Unit = {
        extensions.findByName("android")?.let { ext ->
            runCatching {
                val current = ext.javaClass.getMethod("getCompileSdk").invoke(ext) as? Int
                if (current == null || current < 36) {
                    ext.javaClass.methods
                        .firstOrNull { it.name == "setCompileSdk" && it.parameterTypes.size == 1 }
                        ?.invoke(ext, 36)
                }
            }
        }
        Unit
    }
    if (state.executed) bumpCompileSdk() else afterEvaluate { bumpCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
