import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties()
if (signingPropertiesFile.exists()) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}
val signingKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingSigningKeys = signingKeys.filter {
    signingProperties.getProperty(it).isNullOrBlank()
}
val hasReleaseSigning = signingPropertiesFile.exists() && missingSigningKeys.isEmpty()

val debugSigningPropertiesFile = rootProject.file("debug-signing.local.properties")
if (debugSigningPropertiesFile.exists()) {
    val debugProperties = Properties()
    debugSigningPropertiesFile.inputStream().use { debugProperties.load(it) }
    if (signingKeys.any { debugProperties.getProperty(it).isNullOrBlank() } ||
        !file(debugProperties.getProperty("storeFile", "")).isFile) {
        throw GradleException("Invalid android/debug-signing.local.properties; check the debug signing configuration.")
    }
    android.signingConfigs.getByName("debug") {
        storeFile = file(debugProperties.getProperty("storeFile"))
        storePassword = debugProperties.getProperty("storePassword")
        keyAlias = debugProperties.getProperty("keyAlias")
        keyPassword = debugProperties.getProperty("keyPassword")
    }
}

if (hasReleaseSigning) {
    android.signingConfigs.create("release") {
        keyAlias = signingProperties.getProperty("keyAlias")
        keyPassword = signingProperties.getProperty("keyPassword")
        storeFile = file(signingProperties.getProperty("storeFile"))
        storePassword = signingProperties.getProperty("storePassword")
    }
}

tasks.register("verifyReleaseSigning") {
    doLast {
        if (!hasReleaseSigning) {
            throw GradleException(
                "Android release builds require android/key.properties and a release keystore. " +
                    "Missing properties: ${missingSigningKeys.joinToString()}",
            )
        }
        val storePath = file(signingProperties.getProperty("storeFile"))
        if (!storePath.isFile) {
            throw GradleException("Release keystore does not exist; check storeFile in key.properties.")
        }
    }
}

tasks.configureEach {
    if (name == "preReleaseBuild") dependsOn("verifyReleaseSigning")
}

android {
    namespace = "win.huarun.huarunwin"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging.resources.merges += "META-INF/LICENSE.md"
    packaging.resources.excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "win.huarun.huarunwin"
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
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            proguardFiles("proguard-rules.pro")
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
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

// ARSCLib's desktop JAR bundles Android/XML Pull interfaces. Android supplies
// these types; packaging them makes R8 treat framework implementations as absent.
val arscLibrary by configurations.creating
val androidArscLibrary by tasks.registering(Jar::class) {
    archiveBaseName.set("arsclib-android")
    archiveVersion.set("1.4.0")
    destinationDirectory.set(layout.buildDirectory.dir("android-libraries"))
    from({ zipTree(arscLibrary.singleFile) }) {
        exclude("android/**", "org/xmlpull/**")
    }
}

dependencies {
    implementation("androidx.core:core:1.13.1")
    implementation("com.android.tools.build:apksig:8.5.2")
    arscLibrary("io.github.reandroid:ARSCLib:1.4.0")
    implementation(files(androidArscLibrary))
    implementation("org.bouncycastle:bcpkix-jdk18on:1.86")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
