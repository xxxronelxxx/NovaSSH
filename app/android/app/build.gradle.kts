import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// === NovaSSH Rust bridge ===
// Cross-compiles nova_core for the Android ABIs and drops the .so files into
// jniLibs, where the Flutter/FRB loader expects them.
val novaRepoDir = file("$projectDir/../../..")
val novaSdkDir = System.getenv("ANDROID_HOME")
    ?: System.getenv("ANDROID_SDK_ROOT")
    ?: file("$projectDir/../../../local.properties").takeIf { it.exists() }
        ?.readLines()
        ?.firstOrNull { it.startsWith("sdk.dir=") }
        ?.substringAfter("sdk.dir=")
val novaNdkDir = System.getenv("ANDROID_NDK_HOME")
    ?: novaSdkDir?.let { sdk ->
        file("$sdk/ndk").listFiles()?.sortedBy { it.name }?.lastOrNull()?.absolutePath
    }

// release scripts pass -PnovaAbis=arm64-v8a or the full universal set.
val novaAbis = (project.findProperty("novaAbis") as String?)
    ?.split(',')
    ?.map { it.trim() }
    ?.filter { it.isNotEmpty() }
    ?: listOf("arm64-v8a")
val novaJniLibsDir = file("$projectDir/src/main/jniLibs")

val novaCargoNdkBuild = tasks.register<Exec>("novaCargoNdkBuild") {
    workingDir = novaRepoDir
    novaNdkDir?.let { environment("ANDROID_NDK_HOME", it) }
    environment("CARGO_TARGET_DIR", "$novaRepoDir/rust/core/target")
    commandLine(
        buildList {
            add("cargo")
            add("ndk")
            novaAbis.forEach {
                add("-t")
                add(it)
            }
            add("-o")
            add(novaJniLibsDir.absolutePath)
            add("build")
            add("--release")
            add("--manifest-path")
            add("$novaRepoDir/rust/core/Cargo.toml")
        }
    )
    // A stale .so or a previous ABI set must not leak into this APK.
    doFirst {
        novaJniLibsDir.deleteRecursively()
        novaJniLibsDir.mkdirs()
    }
    inputs.property("novaAbis", novaAbis.joinToString(","))
    inputs.dir("$novaRepoDir/rust/core/src")
    inputs.files("$novaRepoDir/rust/core/Cargo.toml", "$novaRepoDir/Cargo.lock")
    outputs.dir(novaJniLibsDir)
    outputs.upToDateWhen { false }
}

android {
    namespace = "ru.devspb.nova"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ru.devspb.nova"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Local builds without the release key still run.
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

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
        dependsOn(novaCargoNdkBuild)
    }
}
