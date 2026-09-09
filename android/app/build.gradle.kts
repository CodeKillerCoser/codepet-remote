plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStoreFile = providers.gradleProperty("CODEPET_RELEASE_STORE_FILE")
    .orNull ?: System.getenv("CODEPET_RELEASE_STORE_FILE")
val releaseStorePassword = providers.gradleProperty("CODEPET_RELEASE_STORE_PASSWORD")
    .orNull ?: System.getenv("CODEPET_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = providers.gradleProperty("CODEPET_RELEASE_KEY_ALIAS")
    .orNull ?: System.getenv("CODEPET_RELEASE_KEY_ALIAS")
val releaseKeyPassword = providers.gradleProperty("CODEPET_RELEASE_KEY_PASSWORD")
    .orNull ?: System.getenv("CODEPET_RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "com.codepet.remote"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.codepet.remote"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("repositoryDebug") {
            storeFile = rootProject.file("keystore/codepet-debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("repositoryDebug")
            // Install native transport probes alongside the user's normal app.
            if (System.getenv("CODEPET_RTC_PROBE") == "true") {
                applicationIdSuffix = ".rtcprobe"
            }
        }
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// Release must never fall back to the public repository debug identity.
gradle.taskGraph.whenReady {
    val packagesApp = allTasks.any {
        it.project == project &&
            it.name.matches(Regex("(assemble|bundle|package|install).*Release.*"))
    }
    if (packagesApp && !hasReleaseSigning) {
        throw GradleException("Configure all CODEPET_RELEASE_* signing values before building a release APK; debug signing fallback is disabled.")
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
