import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 有 android/key.properties 就用自己的 release 签名，没有就退回 debug 签名。
// 这样没配密钥时构建照常，配好后自动生效。
// key.properties 和 .jks 都不进版本库，见 .gitignore。
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.phonetool.phone_ai_assistant"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        // flutter_local_notifications 用了 java.time 那套 API，而 minSdk 是 24，
        // 老系统上没有——脱糖（desugaring）把它们打进 APK 顶上。
        // 不开的话构建直接失败：「requires core library desugaring to be enabled」。
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.phonetool.phone_ai_assistant"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 两个入口（主 App 和读书版）必须是两个独立应用，不然装读书版会把主 App
    // 顶掉——同一个 applicationId 在安卓看来就是同一个程序，覆盖安装。
    //
    // 用 flavor 而不是两个仓库：代码共用一份，只有包名和显示名不同。
    //   主  App：flutter build apk --release --flavor assistant
    //   读书版：flutter build apk --release --flavor reading -t lib/main_reading.dart
    flavorDimensions += "app"
    productFlavors {
        // ⚠️ 不能叫 "main"——那是安卓保留的 source set 名，
        // 会报 "Multiple entries with same key: main=[]"。
        create("assistant") {
            dimension = "app"
            // 不加后缀，保持原来的包名——已经装在她手机上的那个不能变，
            // 变了等于换了个应用，数据全丢。
        }
        create("reading") {
            dimension = "app"
            applicationIdSuffix = ".reading"
            resValue("string", "app_name", "读书讨论")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    // 没配 key.properties 时仍用 debug 密钥，保证 `flutter run --release` 能跑。
                    signingConfigs.getByName("debug")
                }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 脱糖用的运行时库，配合上面的 isCoreLibraryDesugaringEnabled。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
