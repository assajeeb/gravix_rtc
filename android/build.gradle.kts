group = "com.gravitycompile.gravix_cloud"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

plugins {
    id("com.android.library")
}

// Studio noise suppression (DeepFilterNet3 on a private ONNX Runtime, arm64-v8a
// only, ~5.8 MB). An app drops it with `gravixNsStudio=false` in its
// gradle.properties: RNNoise stays (libgxns, ~125-160 KB per ABI).
val gravixNsStudio: Boolean = (findProperty("gravixNsStudio") ?: rootProject.findProperty("gravixNsStudio"))
    ?.toString()?.toBoolean() ?: true

android {
    namespace = "com.gravitycompile.gravix_cloud"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            // arm64-v8a only: libgxort.so (ORT), libgxns_dfn3_std.so (the model),
            // libgxns_dfn3_bench.so / _ref.so (benchmark clip + reference output)
            if (gravixNsStudio) jniLibs.srcDirs("src/studio/jniLibs")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        // libgxns.so (on-device noise suppression, RNNoise). Other ABIs (x86)
        // get no library: GxNsNative falls back to "off" with a reason.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=none", "-DGXNS_STUDIO=" + (if (gravixNsStudio) "ON" else "OFF"))
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Music mixing bridges into flutter_webrtc's audio device module via
    // reflection + the JavaAudioDeviceModule.AudioBufferCallback interface.
    // compileOnly: the classes come from the host app's plugin/gradle graph.
    compileOnly(project(":flutter_webrtc"))
    compileOnly("io.github.webrtc-sdk:android:144.7559.09")
    // Audio routing (GxAudioSwitchManager). flutter_webrtc ships this exact
    // commit as an implementation dependency, so it is on the app runtime
    // classpath already; compileOnly avoids a second copy.
    compileOnly("com.github.davidliu:audioswitch:039a35aefab7747c557242fa216c9ea11743b604")

    // Plain JUnit 4: JVM unit tests (RealFftTest) need no Android runtime.
    testImplementation("junit:junit:4.13.2")
}
