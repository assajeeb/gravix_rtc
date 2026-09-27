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
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
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
