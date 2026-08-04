import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Release signing material is supplied out-of-band and never committed. Provide it in
// android/local.properties (git-ignored) or as environment variables:
//   TB_KEYSTORE, TB_KEYSTORE_PASSWORD, TB_KEY_ALIAS, TB_KEY_PASSWORD
// When TB_KEYSTORE is absent, assembleRelease produces an unsigned APK (sign later with
// apksigner), so local release checks still work without credentials.
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun secret(name: String): String? =
    (localProps.getProperty(name) ?: System.getenv(name))?.takeIf { it.isNotBlank() }

android {
    namespace = "tunnelbahn.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "tunnelbahn.app"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Real target devices are 64-bit ARM (sideloaded, not via Play).
        // Shipping only arm64-v8a drops the x86/x86_64/armeabi-v7a copies of
        // the ~16 MB Go native lib.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        create("release") {
            secret("TB_KEYSTORE")?.let { ks ->
                storeFile = file(ks)
                storePassword = secret("TB_KEYSTORE_PASSWORD")
                keyAlias = secret("TB_KEY_ALIAS")
                keyPassword = secret("TB_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Sign only when credentials are supplied; otherwise leave the APK unsigned
            // rather than failing the build.
            if (secret("TB_KEYSTORE") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation(files("libs/libtunnelbahn.aar"))

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")

    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    // Only material-icons-core; the three glyphs not in the core set are
    // vendored in ui/icons/TbIcons.kt to avoid the ~34 MB extended set.
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
