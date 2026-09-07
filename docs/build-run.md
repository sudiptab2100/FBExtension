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

The project opts out of AGP 9's built-in Kotlin. The pinned Workmanager Android
module otherwise assumes it is enabled, so the root Gradle configuration applies
the existing Kotlin plugin to that module and retains its JVM 1.8 target. Keep
this compatibility hook while `android.builtInKotlin=false`; otherwise the generated
Flutter registrant references a `WorkmanagerPlugin` class that was never compiled.

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

After Flutter has prepared the Android project and its Gradle wrapper, a
resource-constrained local ARM64 install can use the existing Gradle `shrink` property to
skip optional APK shrinking while retaining release-mode Dart code and app behavior:
```bash
source ~/.localdrive_flutter_env.sh
cd android
./gradlew :app:assembleRelease --no-daemon --max-workers=2 \
  -Dorg.gradle.jvmargs='-Xmx4096m -XX:MaxMetaspaceSize=1024m -XX:ReservedCodeCacheSize=256m -XX:ActiveProcessorCount=2' \
  -Pkotlin.compiler.execution.strategy=in-process -Pshrink=false \
  -Ptarget-platform=android-arm64 -Psplit-per-abi=true -Ptarget=lib/main.dart \
  -Pdart-obfuscation=false -Ptrack-widget-creation=false -Ptree-shake-icons=false
# From the repository root:
# adb -s <serial> install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```
This is a per-build choice, not a change to normal release defaults. The APK is larger.
Keep enough free storage and avoid overlapping builds; a very small JVM heap can make
R8 spend most of its time reclaiming memory. Install with `-r` to retain app data.

## iOS notes
The iOS app includes native background tus transfers, early BGTask registration,
headless plugin registration, and local-network/photo/contact permissions.
**Xcode 16.4 and CocoaPods are installed on the build Mac**. Signed physical-device
builds require a valid configured Apple ID team; a successful build does not verify
background execution on a phone. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
is exported by `~/.localdrive_flutter_env.sh`.

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

The iOS bundle id is `com.sudiptab2100.localdriveApp`, with automatic signing.
Preserve the developer's configured team and provisioning; do not replace signing
settings to work around a disconnected device.

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
source ~/.localdrive_flutter_env.sh && xcrun devicectl device install app --device <iphone-id> build/ios/iphoneos/Runner.app
source ~/.localdrive_flutter_env.sh && xcrun devicectl device process launch --device <iphone-id> com.sudiptab2100.localdriveApp
```
The **launch** step fails with `invalid code signature … profile has not been explicitly
trusted` until you trust the cert on the phone (VPN & Device Management, above); after
trusting, tap the home-screen icon or re-run the launch command.

When building directly with `xcodebuild` and `BUILD_DIR="$PWD/build/ios"`, the release
product is `build/ios/Release-iphoneos/Runner.app`. The usual
`build/ios/iphoneos/Runner.app` can still contain an older Flutter build. Verify the
actual product before installing; do not treat a successful Xcode build as evidence
that a different output directory was refreshed.

#### iOS 26 plugin pins (Xcode 16.4 / iOS 18.5 SDK)
Some plugins adopted iOS 26-only APIs that don't compile against the iOS 18.5 SDK bundled with
Xcode 16.4. To keep the app buildable on this host, `pubspec.yaml`:
- pins `workmanager` to `0.9.2+1` and overrides its federated impls to the last pre-iOS-26
  line (`workmanager_apple 0.9.5`, `workmanager_android 0.9.2`,
  `workmanager_platform_interface 0.9.3`) — 0.9.6+ uses `BGContinuedProcessingTask`;
- pins `connectivity_plus` to `6.1.5` and `battery_plus` to `6.2.3` for backup
  eligibility without requiring iOS 26-only APIs. `device_info_plus` remains unused
  and absent.

Once the host upgrades to **Xcode 26** (matching the iPhone's iOS 26 SDK), these pins can be
reevaluated with a full native build; do not remove them blindly.

### Verify reliable backup on a physical iPhone
Use an isolated test server and synthetic media/vCards, never personal content or the
running NAS's storage. Build the coordinated Master update first; older servers are
explicitly foreground-only for backup.

1. Connect/unlock the phone, confirm it is available in `xcrun devicectl list devices`,
   install the signed release, and grant foreground setup permissions.
2. Enable an account-owned destination. Confirm automatic preparation waits for charging
   and the configured Wi-Fi policy; **Back up now** bypasses only charging.
3. Prepare a synthetic upload, background/lock the phone, and inspect the server receipt
   plus the app's reconciled ledger after reopen. Enqueueing alone is not success.
4. Exercise Wi-Fi loss, an isolated server restart, account switching, and replay of an
   unacknowledged completion. Check resumed offsets and one logical completion per job.
5. Treat force-quit as expected transfer cancellation; verify recovery after reopening.
   Test a BGProcessing wake separately from URLSession transfer continuation.

A debugger-triggered BGTask tests the handler, not natural scheduling frequency. A
simulator or build cannot substitute for these observations. If the phone is unavailable,
retain the release artifact and report installation/background demonstration as unverified.

Let the app create its Application Support and backup directories before copying
diagnostic fixtures into them. CoreDevice directory transfers can leave newly created
parents owned by root instead of the app's user, preventing staging/journal writes.
Inspect ownership, preserve any real data, and remove only verified diagnostic
leftovers; never work around this by disabling protection or resetting the database.

## Tests
Flutter unit/widget regressions include:
| File | Coverage |
| --- | --- |
| `test/ld_instance_test.dart` | URL parsing/default ports/JSON. |
| `test/backup_settings_test.dart` | Backup defaults/runnable/JSON. |
| `test/auth_repository_test.dart` | Auth repository parsing/error mapping. |
| `test/models_test.dart` | Data model parsing. |
| `test/files_repository_url_test.dart` | URL builders and byte formatting. |
| `test/background_session_test.dart` | Account/token isolation, legacy ownership, generation and logout races. |
| `test/background_schedule_test.dart` | iOS processing versus Android periodic constraints and stale scheduling. |
| `test/backup_policy_test.dart` | Manual/automatic charging, Wi-Fi, source and account gating. |
| `test/secure_store_test.dart` | Migrated Keychain item access and non-destructive token writes. |
| `test/backup_screen_test.dart` | Truthful queued/waiting/failure states under the real app theme. |
| `test/backup_lifecycle_test.dart` | Reconcile-before-catch-up, overlapping resumes, and signed-out gating. |
| `test/backup_runner_test.dart` | Full queued/paused batch recovery, continuation, debounce and retry backoff. |
| `test/backup_destination_test.dart` | Personal backup folder scope without changing ordinary admin browsing. |
| `test/local_db_open_test.dart` | Shared opening callback, result-returning pragmas, existing schemas and reopening. |
| `test/session_database_test.dart` | Normal-user login after backup pause; no credential switch on real storage/cancellation failure. |

Run all tests with:
```bash
source ~/.localdrive_flutter_env.sh && flutter test
```

Native transport/journal regressions use the existing host XCTest runner:
```bash
source ~/.localdrive_flutter_env.sh && bash ios/RunnerTests/run_native_regressions.sh
```
These cover native identity/recovery, file protection, request validation and
durable completion events. They do not substitute for a signed physical-device
background transfer.

## Verification policy
- Docs-only changes do not require Flutter analyze/test/build, but validate file creation and
  links when practical.
- Dart code changes: run the smallest relevant test; normally also `flutter analyze`.
- Network/platform changes: run `flutter analyze`, `flutter test`, and Android debug build.
- Do not add new tools or linters unless the task explicitly requires it.
