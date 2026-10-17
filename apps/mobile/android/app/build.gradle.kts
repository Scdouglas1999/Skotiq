plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// FCM background push is provisioning-gated: the Google-services plugin
// hard-fails the build when google-services.json is absent, and shipping
// without a Firebase project (LAN-only alerting) must stay a green build.
// Dropping the owner's google-services.json into this directory lights the
// plugin up; PushBridge.kt no-ops at runtime until then.
val googleServicesConfigured = file("google-services.json").exists()
if (googleServicesConfigured) {
    apply(plugin = "com.google.gms.google-services")
    logger.lifecycle("FCM: google-services.json found; Firebase push enabled")
} else {
    logger.lifecycle("FCM: no google-services.json; building with push registration dormant")
}

android {
    namespace = "com.skotiq.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.skotiq.mobile"
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }
    
    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("KEYSTORE_FILE")
            if (keystorePath != null) {
                // Fail-closed: a SET keystore must be complete. Never silently
                // debug-sign a build that was meant to be production.
                val keystore = file(keystorePath)
                if (!keystore.exists()) {
                    throw GradleException("KEYSTORE_FILE is set to '$keystorePath' but no file exists there.")
                }
                val storePass = System.getenv("KEYSTORE_PASSWORD")
                val alias = System.getenv("KEY_ALIAS")
                val keyPass = System.getenv("KEY_PASSWORD")
                if (storePass.isNullOrEmpty() || alias.isNullOrEmpty() || keyPass.isNullOrEmpty()) {
                    throw GradleException("KEYSTORE_FILE is set but KEYSTORE_PASSWORD, KEY_ALIAS, or KEY_PASSWORD is missing.")
                }
                storeFile = keystore
                storePassword = storePass
                keyAlias = alias
                keyPassword = keyPass
                logger.lifecycle("Release signing: production keystore")
            } else {
                val debug = signingConfigs.getByName("debug")
                storeFile = debug.storeFile
                storePassword = debug.storePassword
                keyAlias = debug.keyAlias
                keyPassword = debug.keyPassword
                logger.lifecycle("Release signing: debug keystore (unsigned beta)")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // ShortcutManagerCompat for App Actions / Assistant
    // shortcuts. Provides pushDynamicShortcut + updateShortcuts which
    // MainActivity uses to surface the live sequence status to the
    // launcher and Assistant.
    implementation("androidx.core:core-ktx:1.13.1")
    // Firebase Cloud Messaging client (see PushBridge.kt). Compiled in
    // unconditionally so the `skotiq/push` channel surface always exists;
    // without google-services.json FirebaseApp.initializeApp returns null and
    // registration reports `fcm_unconfigured` instead of running.
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
}
