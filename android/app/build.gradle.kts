import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
}

val repositoryRoot = rootProject.projectDir.parentFile
val generatedNativeDir = layout.buildDirectory.get().dir("generated/pocketimg/jniLibs").asFile
val generatedBackend = generatedNativeDir.resolve("arm64-v8a/libpocketimg.so")

val buildGoBackend by tasks.registering(Exec::class) {
    group = "build"
    description = "Build the embedded PocketIMG Go backend for Android ARM64"
    workingDir(repositoryRoot)
    environment("CGO_ENABLED", "0")
    environment("GOOS", "android")
    environment("GOARCH", "arm64")
    environment("GOTOOLCHAIN", "auto")
    inputs.files(
        fileTree(repositoryRoot.resolve("cmd")),
        fileTree(repositoryRoot.resolve("internal")),
        repositoryRoot.resolve("go.mod"),
        repositoryRoot.resolve("go.sum"),
    )
    outputs.file(generatedBackend)
    doFirst { generatedBackend.parentFile.mkdirs() }
    commandLine(
        "go", "build",
        "-tags=nodynamic",
        "-buildmode=pie",
        "-trimpath",
        "-ldflags=-s -w",
        "-o", generatedBackend.absolutePath,
        "./cmd/server",
    )
}

val keystoreProperties = Properties().apply {
    val propertiesFile = rootProject.file("keystore.properties")
    if (propertiesFile.isFile) propertiesFile.inputStream().use(::load)
}

fun signingValue(environmentName: String, propertyName: String): String? =
    providers.environmentVariable(environmentName).orNull?.takeIf(String::isNotBlank)
        ?: keystoreProperties.getProperty(propertyName)?.takeIf(String::isNotBlank)

val releaseStoreFile = signingValue("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")
val releaseSigningConfigured = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }

val releaseVersionCode =
    providers.environmentVariable("PIH_ANDROID_VERSION_CODE").orNull?.toIntOrNull() ?: 7
val releaseVersionName =
    providers.environmentVariable("PIH_ANDROID_VERSION_NAME").orNull?.takeIf(String::isNotBlank) ?: "0.2.1"

android {
    namespace = "com.gmch.pocketimg"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.gmch.pocketimg"
        minSdk = 26
        targetSdk = 36
        versionCode = releaseVersionCode
        versionName = releaseVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
    }

    sourceSets.getByName("main").jniLibs.directories.add(generatedNativeDir.absolutePath)

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = rootProject.file(requireNotNull(releaseStoreFile))
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (releaseSigningConfigured) signingConfig = signingConfigs.getByName("release")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libpocketimg.so"
        }
    }
}

tasks.named("preBuild").configure { dependsOn(buildGoBackend) }

dependencies {
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.core.ktx)
    testImplementation(libs.junit)
}
