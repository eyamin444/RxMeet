// android/settings.gradle.kts
pluginManagement {
    // Load flutter.sdk from ANDROID/local.properties
    val props = java.util.Properties().apply {
        val f = java.io.File(settingsDir, "local.properties")
        if (!f.exists()) throw GradleException("local.properties not found at: ${f.absolutePath}")
        f.inputStream().use { load(it) }
    }
    println(">>> Using local.properties at: ${java.io.File(settingsDir, "local.properties").absolutePath}")
    println(">>> flutter.sdk = ${props.getProperty("flutter.sdk")}")

    val flutterSdk = props.getProperty("flutter.sdk")
        ?: throw GradleException("`flutter.sdk` not set in local.properties")

    // Use Flutter's included build so it wires tasks correctly
    includeBuild("$flutterSdk/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }

    // We only need app plugin + Flutter loader versions here
    plugins {
        id("dev.flutter.flutter-plugin-loader") version "1.0.0"
        id("com.android.application") version "8.6.1"
        // 👉 DO NOT declare org.jetbrains.kotlin.android here anymore
    }
}

// Only apply the Flutter loader at settings level
plugins {
    id("dev.flutter.flutter-plugin-loader")
}

include(":app")
