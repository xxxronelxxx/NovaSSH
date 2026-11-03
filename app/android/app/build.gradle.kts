plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

val novaCargoNdkBuild = tasks.register<Exec>("novaCargoNdkBuild") {
    workingDir = novaRepoDir
    novaNdkDir?.let { environment("ANDROID_NDK_HOME", it) }
    environment("CARGO_TARGET_DIR", "$novaRepoDir/rust/core/target")
    // Phone builds only need arm64: it halves the build time and the APK size
    // (add more targets here if a 32-bit or emulator build is ever needed).
    commandLine(
        "cargo", "ndk",
        "-t", "arm64-v8a",
        "-o", "$projectDir/src/main/jniLibs",
        "build", "--release",
        "--manifest-path", "$novaRepoDir/rust/core/Cargo.toml"
    )
    // Cargo itself is incremental, but Gradle must never skip this task: a
    // stale .so breaks the bridge (FRB reports a content hash mismatch and the
    // app hangs on the splash screen).
    inputs.dir("$novaRepoDir/rust/core/src")
    inputs.files("$novaRepoDir/rust/core/Cargo.toml", "$novaRepoDir/Cargo.lock")
    outputs.dir("$projectDir/src/main/jniLibs")
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
