plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.coffye.rcerfb"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.16248370" // <--- أضف هذا السطر هنا

compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

    defaultConfig {
        applicationId = "com.coffye.rcerfb" // Must match live Play Store app
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = 2
        versionName = "1.0.1"
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            
            // Khalli haydoune false (aw em7ihon):
            isMinifyEnabled = false
            isShrinkResources = false
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
