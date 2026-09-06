# Permissions

Platform permissions map directly to discovery, QR scanning, uploads, notifications, and backup features.

## Android manifest
Source: `android/app/src/main/AndroidManifest.xml`.

| Permission | Feature using it |
| --- | --- |
| `android.permission.INTERNET` | LAN HTTP/HTTPS calls to LocalDrive-Master. |
| `android.permission.ACCESS_NETWORK_STATE` | WorkManager/network-aware behavior. |
| `android.permission.ACCESS_WIFI_STATE` | LAN/Wi-Fi discovery and Wi-Fi-related backup constraints. |
| `android.permission.CHANGE_WIFI_MULTICAST_STATE` | mDNS/Bonjour discovery on Wi-Fi. |
| `android.permission.CAMERA` | QR scanning in `QrScanScreen`. |
| `android.permission.READ_MEDIA_IMAGES` | Photo picker/auto-backup image access on Android 13+. |
| `android.permission.READ_MEDIA_VIDEO` | Video picker/auto-backup video access on Android 13+. |
| `android.permission.READ_CONTACTS` | Contacts export and contacts auto-backup. |
| `android.permission.READ_EXTERNAL_STORAGE` (`maxSdkVersion=32`) | Legacy file/media read access on Android 12 and below. |
| `android.permission.POST_NOTIFICATIONS` | File/access/backup local notifications on Android 13+. |
| `android.permission.WAKE_LOCK` | Background WorkManager execution. |
| `android.permission.RECEIVE_BOOT_COMPLETED` | WorkManager rescheduling after boot. |
| `android.permission.FOREGROUND_SERVICE` | Background upload/backup service support. |
| `android.permission.FOREGROUND_SERVICE_DATA_SYNC` | Data-sync foreground service classification on newer Android. |

Manifest queries allow Flutter's text processing and external viewers for downloaded files:
`ACTION_PROCESS_TEXT` (`text/plain`) and `ACTION_VIEW` (`*/*`).

## Android SDK configuration
Source: `android/app/build.gradle.kts`.

| Setting | Value |
| --- | --- |
| `namespace` / `applicationId` | `com.sudiptab2100.localdrive_app` |
| `minSdk` | `26` |
| `compileSdk` | `36` pinned |
| Java target | 17 with core library desugaring |

`android/build.gradle.kts` also pins plugin modules to compile SDK 36 to avoid API-37 build
breaks on this host. Keep `permission_handler` at `^11.3.1` unless the build issue is fixed.

## iOS Info.plist
Source: `ios/Runner/Info.plist`.

| Entry | Feature using it |
| --- | --- |
| `NSLocalNetworkUsageDescription` | LAN server discovery/connection. |
| `NSBonjourServices` = `_localdrive._tcp`, `_http._tcp` | Bonjour discovery service types. |
| `NSCameraUsageDescription` | QR code scanning. |
| `NSPhotoLibraryUsageDescription` | Selecting/backing up photos and videos. |
| `NSPhotoLibraryAddUsageDescription` | Saving downloaded files to the photo library when applicable. |
| `NSContactsUsageDescription` | Contacts vCard export and backup. |
| `UIBackgroundModes` = `fetch`, `processing` | Background polling and backup. |
| `BGTaskSchedulerPermittedIdentifiers` | `com.sudiptab2100.localdrive_app.refresh`, `.backup`. |

The Xcode project currently sets `IPHONEOS_DEPLOYMENT_TARGET = 15.0`; although the product
requirement mentions iOS 13 minimum, the checked-in scaffold is presently targeting 15.0 and
needs Xcode validation/signing on the user's Mac.
