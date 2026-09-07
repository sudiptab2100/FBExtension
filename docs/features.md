# Features

User-facing capabilities are implemented as Flutter feature folders backed by repositories and services.

## Connection and auth
| Feature | Code | API/service |
| --- | --- | --- |
| Saved servers | `ConnectScreen`, `ConnectionController`, `Prefs` | `ld.instances`, `ld.active_instance`. |
| LAN discovery | `DiscoveryService`, `discoveredInstancesProvider` | mDNS `_localdrive._tcp`, filtered `_http._tcp`. |
| QR connection | `QrScanScreen` | `mobile_scanner`, `LdInstance.tryParse()`. |
| Manual connection | `ConnectScreen._ManualEntrySheet` | default ports 4820/4843. |
| Health validation | `ConnectController`, `ConnectRepository` | `GET /api/health`. |
| Self-signed TLS approval | `ConnectScreen._offerTrust()`, `buildDio()`, `_TusClient` | per-instance `trustSelfSigned`. |
| Login/register/logout/session restore | `LoginScreen`, `SessionController`, `AuthRepository` | `/api/auth/*`, secure JWT storage. |
| Multiple saved accounts | `account_switcher.dart`, `SessionController`, `Prefs` | Per-account tokens and verified IDs; switching pauses the previous account's backup. |

## Main shell
`HomeShell` is a bottom navigation shell with four tabs:
| Tab | Screen | Summary |
| --- | --- | --- |
| Drives | `DrivesScreen` | Registered drives, access state, request access, admin view-mode/admin-console shortcuts. |
| Device | `DeviceScreen` | Upload photos/videos, arbitrary files, or contacts from the phone. |
| Backup | `BackupScreen` | Configure/run automatic backup. |
| Settings | `SettingsScreen` | Account, server switching, admin view mode, theme, notification toggle, sign-out. |

## Drives and files
| Feature | Code | API |
| --- | --- | --- |
| Drive list/access | `drives_screen.dart` | `GET /api/drives`, `POST /api/drives/request-access`. |
| Admin view mode | `DrivesScreen._ViewModeButton`, `SettingsScreen` | `ld_view=admin|user`. |
| File browser | `file_browser_screen.dart` | `GET /api/files/list`. |
| File operations | `file_browser_screen.dart`, `FilesRepository` | mkdir, rename, move, copy, delete endpoints. |
| Upload files | `UploadProgressDialog`, `UploadService` | tus `/api/upload`. |
| Search | `search_screen.dart` | `GET /api/search`. |
| Thumbnails/previews | `file_thumbnail.dart`, `_PreviewScreen` | `/api/files/thumb`, `/api/files/raw`. |
| Download/open/share | `FilesRepository.downloadToFile`, `open_filex`, `share_plus` | `/api/files/download`. |

Known limitation: video preview screen opens the media externally instead of rendering an
in-app video player.

## Device uploads
| Source | Code | Behavior |
| --- | --- | --- |
| Photos/videos | `PhotoGridScreen`, `MediaService` | Requests gallery access, paginates albums/assets, uploads selected `XFile`s. |
| Files | `DeviceScreen`, `file_picker` | Picks documents/files and uploads to a selected destination. |
| Contacts | `DeviceScreen`, `MediaService.exportContactsVcf()` | Exports all contacts to one `.vcf` and uploads it. |
| Destination | `destination_picker.dart` | Chooses an online granted writable drive and folder. |

## Notifications and backup
| Feature | Code | Backend |
| --- | --- | --- |
| Foreground change alerts | `LiveEventsController` | `GET /api/events/user`. |
| Background change alerts | `BackgroundService._pollChanges()` | `GET /api/changes?since=<cursor>`. |
| Notification toggle | `notificationsEnabledProvider`, `SettingsScreen` | `ld.notifications_enabled`. |
| Account-owned settings | `BackupSettings`, `BackupScreen` | `ld.backup_profile.<profileId>`; old global settings require explicit import. |
| Manual and automatic backup | `BackupRunner`, `BackupCoordinator` | Shared durable queue; manual mode bypasses charging only. |
| iOS background backup | `runHeadlessBackup()`, native upload bridge | BGProcessing preparation plus file-backed background URLSession tus transfers. |
| Android background backup | `runHeadlessBackup()` | WorkManager periodic task and resumable Dart transport. |
| Foreground catch-up | `LocalDriveApp`, `BackupRunner` | Launch/resume/network/power changes; bounded continuation and retry backoff. |
| Dedupe and recovery | `LocalDb`, `BackupTusService` | Account/destination/source-scoped ledger, server receipts, commit-before-ACK native events. |
| Truthful progress | `BackupSnapshot`, `BackupScreen` | Preparing, queued, uploading, paused, waiting, failed and complete; last attempt/success. |

Automatic preparation defaults to Wi-Fi and charging. The Mac/drive must be reachable,
and access/source permissions are still required. iOS controls scanning windows;
force-quit prevents automatic relaunch until reopen. See
[notifications-backup.md](notifications-backup.md) for limits and completion semantics.

## Admin console
Admin users can open Settings → Admin console.
| Screen | Code | API |
| --- | --- | --- |
| Dashboard | `AdminDashboardScreen` | `GET /api/stats`. |
| Users | `AdminUsersScreen` | list/create/delete/approve/password/role under `/api/users`. |
| Access requests | `AdminAccessScreen` | `/api/access`, approve/deny subpaths. |
| Configuration | `AdminConfigScreen` | `GET/PATCH /api/config`. |
| Server control | `AdminServerScreen` | `/api/server/start|stop|restart`, status from stats. |

The mobile admin UI summarizes ACL counts but does not currently expose a dedicated ACL edit
screen despite repository support for `POST/DELETE /api/users/acls`.
