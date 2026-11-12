// AGP 9 compiles the Kotlin sources itself (built-in Kotlin: no kotlin-android
// plugin; src/main/kotlin is a default source folder, and Kotlin's JVM target
// follows compileOptions).
plugins {
    id("com.android.application") version "9.3.1"
}

android {
    namespace = "com.amoledwatch.camerahelper"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.amoledwatch.camerahelper"
        minSdk = 26
        targetSdk = 36
        versionCode = (project.findProperty("helperVersionCode") as String?)?.toIntOrNull() ?: 1
        versionName = (project.findProperty("helperVersionName") as String?) ?: "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The same key as the main app (build.yml's secrets): the main app's
    // signature permission lets only it ask the helper to press buttons.
    val keystore = System.getenv("ANDROID_KEYSTORE_PATH")
    signingConfigs {
        if (keystore != null && file(keystore).exists()) {
            create("stable") {
                storeFile = file(keystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")?.trim()
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")?.trim()
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")?.trim()
            }
        }
    }
    buildTypes {
        val signing = signingConfigs.findByName("stable") ?: signingConfigs.getByName("debug")
        debug { signingConfig = signing }
        release {
            signingConfig = signing
            isMinifyEnabled = false
        }
    }
}
