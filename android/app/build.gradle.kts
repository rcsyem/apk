plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}
android {
    namespace = "app.localai.assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "26.3.11579264"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    defaultConfig {
        applicationId = "app.localai.assistant"
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a") }   // ARM64 only
        externalNativeBuild {
            cmake { arguments += listOf("-DANDROID_STL=c++_shared") }  // baseline arm64-v8a; no -march override
        }
    }
    externalNativeBuild { cmake { path = file("../../native/CMakeLists.txt"); version = "3.22.1" } }
    buildTypes { release { signingConfig = signingConfigs.getByName("debug") } }
}
flutter { source = "../.." }
