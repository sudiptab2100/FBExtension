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

## iOS notes
The iOS folder is scaffolded and Info.plist includes local network, Bonjour, camera, photo,
contacts, and BGTask entries. This host is **scaffold-only** for iOS: no full Xcode/signing
validation. Build and sign iOS on the user's Mac with Xcode.

Checked-in Xcode project deployment target is `15.0`. If product policy requires iOS 13,
change and validate it deliberately in Xcode rather than only editing docs.

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
