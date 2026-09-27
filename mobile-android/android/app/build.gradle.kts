import java.util.Properties
import java.io.FileInputStream
import com.android.build.api.dsl.ApplicationExtension

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// AGP 9.1's Kotlin DSL: `java.util`/`java.io` collide with Gradle's own
// `java` DSL accessor inside a plain `android { ... }` block (real CI
// error: "Unresolved reference 'util'" / "'io'"), and the classic
// `android { ... }` block itself is being phased out in favor of
// explicitly configuring the ApplicationExtension — hence the explicit
// imports above and `extensions.configure<ApplicationExtension>` below,
// exactly as confirmed against the real build log.
extensions.configure<ApplicationExtension> {
    // Matches spec §3 app_icon/branding requirement — see assets/branding.
    // Deliberately "eu.ministrant.manager", NOT the "eu.ministrant.ministrant_manager"
    // flutter create derives by default from --org/--project-name — this
    // must match MainActivity.kt's actual package path
    // (android/app/src/main/kotlin/eu/ministrant/manager/MainActivity.kt).
    namespace = "eu.ministrant.manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "eu.ministrant.manager"
        // Dynamic (flutter.*Version) rather than hardcoded: Flutter 3.47.3's
        // own bundled defaults already satisfy the minSdk>=24/compileSdk>=36/
        // targetSdk=36 floor from review — letting Flutter's tooling own
        // these means they track forward automatically on the next Flutter
        // upgrade instead of silently drifting stale again.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Fill in from a keystore.properties (NOT committed) before
            // building app-release.aab / app-release.apk for real
            // distribution — see android-build.yml's "Decode release
            // keystore" CI step, which writes android/key.properties.
            val keystorePropertiesFile = rootProject.file("key.properties")
            if (keystorePropertiesFile.exists()) {
                val keystoreProperties = Properties()
                keystoreProperties.load(FileInputStream(keystorePropertiesFile))
                storeFile = keystoreProperties["storeFile"]?.let { rootProject.file(it as String) }
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // Falls back to debug signing when no key.properties exists
            // (e.g. `flutter build apk --debug` / CI's non-release runs),
            // so the app still builds out of the box for testing.
            signingConfig = if (rootProject.file("key.properties").exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
