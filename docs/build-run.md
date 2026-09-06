# Build, run, and test

On this host every Flutter command must source the LocalDrive Flutter environment script first.

## Host setup quirk
Use this prefix for all Flutter commands:
```bash
source ~/.localdrive_flutter_env.sh && flutter <command>
```
The script sets PATH for Flutter/JDK/Android SDK plus `ANDROID_HOME` and `JAVA_HOME`.

## Golden path
```bash
source ~/.localdrive_flutter_env.sh && flutter pub get
source ~/.localdrive_flutter_env.sh && flutter analyze
source ~/.localdrive_flutter_env.sh && flutter test
source ~/.localdrive_flutter_env.sh && flutter build apk --debug
```

## Running locally
```bash
source ~/.localdrive_flutter_env.sh && flutter devices
source ~/.localdrive_flutter_env.sh && flutter run
```
Run LocalDrive-Master separately and connect to `http://<mac-lan-ip>:4820` or scan the QR
from the server's Connect surface.

## Android notes
| Setting | Source | Value / rule |
| --- | --- | --- |
| `applicationId` / namespace | `android/app/build.gradle.kts` | `com.sudiptab2100.localdrive_app` |
| `minSdk` | `android/app/build.gradle.kts` | 26 |
| `compileSdk` | `android/app/build.gradle.kts`, `android/build.gradle.kts` | 36 pinned; do not revert. |
| Java | Gradle | 17, with core library desugaring. |
| `permission_handler` | `pubspec.yaml` | `^11.3.1`; pinned to avoid API-37 build break here. |

Debug APK validation command:
```bash
source ~/.localdrive_flutter_env.sh && flutter build apk --debug
```

### Install on a physical Android device
Requires **Android 8.0+** (`minSdk 26`). No signing account is needed; the release build is
debug-signed by the default template, so it installs for testing.

USB (direct install):
1. On the phone, enable Developer options (**Settings → About phone → tap Build number 7×**)
   then **Settings → System → Developer options → USB debugging**.
2. Plug in via USB and approve the **Allow USB debugging** prompt.
3. Install + run:
```bash
source ~/.localdrive_flutter_env.sh && flutter devices        # phone should appear
source ~/.localdrive_flutter_env.sh && flutter run --release  # build, install, run
```
Or install a prebuilt APK straight to the device:
```bash
source ~/.localdrive_flutter_env.sh && adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Sideload (no cable / share to testers): copy `app-release.apk` to the phone (Drive, email, or
file transfer), open it, allow **Install unknown apps** for the source app, then tap Install.

Shareable release artifact:
```bash
source ~/.localdrive_flutter_env.sh && flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk
```
The debug APK (`app-debug.apk`) is much larger; prefer the release APK for distribution. For a
production/store build, add a real keystore via `android/key.properties` and replace the debug
`signingConfig` in `android/app/build.gradle.kts`.

## iOS notes
The iOS folder is scaffolded and Info.plist includes local network, Bonjour, camera, photo,
contacts, and BGTask entries. **Xcode 16.4 and CocoaPods 1.17 are now installed on the
build Mac**, so iOS is buildable here (Simulator with no signing; a physical device needs an
Apple ID team). `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is exported by
`~/.localdrive_flutter_env.sh`.

One-time host setup (requires the user's password once — Copilot cannot run `sudo`):
```bash
sudo sh -c 'xcode-select -s /Applications/Xcode.app/Contents/Developer && xcodebuild -license accept && xcodebuild -runFirstLaunch'
```

Simulator build/run (no signing, good for compile validation):
```bash
source ~/.localdrive_flutter_env.sh && open -a Simulator
source ~/.localdrive_flutter_env.sh && flutter run -d iphone   # or: flutter build ios --simulator
```

Checked-in Xcode project deployment target is `15.0`. If product policy requires iOS 13,
change and validate it deliberately in Xcode rather than only editing docs.

Checked-in iOS bundle id is `com.sudiptab2100.localdriveApp`, `CODE_SIGN_STYLE = Automatic`,
and no `DEVELOPMENT_TEAM` (each developer sets their own team in Xcode).

### Install on a physical iPhone (sideload for testing)
Requires a Mac with **full Xcode** (not just Command Line Tools) and **CocoaPods** installed,
plus an Apple ID. A free Apple ID works for personal testing.

One-time toolchain setup (only if the host has just Command Line Tools):
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo gem install cocoapods    # or: brew install cocoapods
```

Signing (one-time): open `ios/Runner.xcworkspace` in Xcode, select the **Runner** target →
**Signing & Capabilities** → enable **Automatically manage signing** → choose your **Team**
(add your Apple ID via *Add an Account…*). If the bundle id is unavailable, make it unique.

Install:
```bash
source ~/.localdrive_flutter_env.sh && flutter devices        # confirm the iPhone appears
source ~/.localdrive_flutter_env.sh && flutter run --release -d <iphone-id>
```
On iOS 16+ enable **Settings → Privacy & Security → Developer Mode** first, and after the
first install trust the developer cert under **Settings → General → VPN & Device Management**.
On first launch allow the **Local Network** prompt and keep the phone on the same Wi‑Fi as the
LocalDrive-Master host.

Limits: a **free** Apple ID re-signs every **7 days** (re-run `flutter run` to reinstall) with
at most 3 apps per device; a **paid** Apple Developer account ($99/yr) lasts a year and unlocks
TestFlight for over-the-air installs.

#### Install without staying attached (devicectl)
`flutter run` stays attached to the process. To just build, install, and detach:
```bash
source ~/.localdrive_flutter_env.sh && flutter build ios --release
xcrun devicectl device install app --device <iphone-id> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <iphone-id> com.sudiptab2100.localdriveApp
```
The **launch** step fails with `invalid code signature … profile has not been explicitly
trusted` until you trust the cert on the phone (VPN & Device Management, above); after
trusting, tap the home-screen icon or re-run the launch command.

#### iOS 26 plugin pins (Xcode 16.4 / iOS 18.5 SDK)
Some plugins adopted iOS 26-only APIs that don't compile against the iOS 18.5 SDK bundled with
Xcode 16.4. To keep the app buildable on this host, `pubspec.yaml`:
- pins `workmanager` to `0.9.2+1` and overrides its federated impls to the last pre-iOS-26
  line (`workmanager_apple 0.9.5`, `workmanager_android 0.9.2`,
  `workmanager_platform_interface 0.9.3`) — 0.9.6+ uses `BGContinuedProcessingTask`;
- drops `connectivity_plus`/`device_info_plus` (both unused in Dart) because their current
  releases reference `NWPath.isUltraConstrained` / `NSProcessInfo.isiOSAppOnVision`.

Once the host upgrades to **Xcode 26** (matching the iPhone's iOS 26 SDK), these pins can be
lifted and the plugins restored.

## Tests
Current tests are pure Dart/Flutter unit tests:
| File | Coverage |
| --- | --- |
| `test/ld_instance_test.dart` | URL parsing/default ports/JSON. |
| `test/backup_settings_test.dart` | Backup defaults/runnable/JSON. |
| `test/auth_repository_test.dart` | Auth repository parsing/error mapping. |
| `test/models_test.dart` | Data model parsing. |
| `test/files_repository_url_test.dart` | URL builders and byte formatting. |

Run all tests with:
```bash
source ~/.localdrive_flutter_env.sh && flutter test
```

## Verification policy
- Docs-only changes do not require Flutter analyze/test/build, but validate file creation and
  links when practical.
- Dart code changes: run the smallest relevant test; normally also `flutter analyze`.
- Network/platform changes: run `flutter analyze`, `flutter test`, and Android debug build.
- Do not add new tools or linters unless the task explicitly requires it.
