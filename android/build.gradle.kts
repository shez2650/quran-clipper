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
// Some plugins ask for compileSdk 37, which the current SDK publishes as
// "android-37.0" and AGP can't resolve. Build every plugin against the same
// SDK as the app instead.
subprojects {
    val pinCompileSdk: Project.() -> Unit = {
        extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.compileSdk = 36
    }
    if (state.executed) pinCompileSdk() else afterEvaluate { pinCompileSdk() }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
