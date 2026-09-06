# Notifications and backup

Foreground SSE, background polling, local notifications, and auto-backup share persisted instance/session state.

## Foreground live events
`LocalDriveApp` watches `liveEventsProvider` for the app lifetime. While authenticated,
`LiveEventsController` opens:
```text
GET /api/events/user
```
using Dio streaming with bearer auth and admin `ld_view` if applicable.

| SSE event | App behavior |
| --- | --- |
| `filesChanged` | Invalidates `fileListProvider`; posts a local notification unless disabled or self-authored (`by` matches current username). |
| `accessChanged` | Invalidates `drivesListProvider`; may notify that drive access changed. |
| `drivesChanged` | Invalidates `drivesListProvider`. |
| keepalive comments / `hello` | Parsed/ignored unless used by future code. |

The SSE parser in `sse_client.dart` supports named `event:` frames, multiline `data:`, and
ignores `:` keepalive comments.

## Background changes polling
`BackgroundService.initialize()` registers the WorkManager dispatcher. When notifications are
enabled, periodic refresh work is registered as:
| Constant | Value |
| --- | --- |
| `BgTasks.refresh` | `com.sudiptab2100.localdrive_app.refresh` |
| Period | `BgTasks.minPeriod` = 15 minutes |
| Constraint | connected network |

The background isolate runs `_pollChanges()` without Riverpod:
1. reads `ld.instances` from SharedPreferences;
2. reads each instance token from secure storage (`ld.token.<id>`);
3. reads per-instance cursor `ld.change_cursor.<id>`;
4. calls `GET /api/changes` or `GET /api/changes?since=<cursor>`;
5. stores the returned cursor;
6. posts notifications only when notifications are enabled and this is not the first poll.

The first poll intentionally passes no `since`, so LocalDrive-Master returns an empty initial
feed plus a cursor and the app avoids flooding history.

## Local notifications
`NotificationService` wraps `flutter_local_notifications` and creates two Android channels:
| Channel | Constant | Use |
| --- | --- | --- |
| LocalDrive activity | `Notif.channelId = localdrive_changes` | File/access change alerts. |
| LocalDrive backup | `Notif.backupChannelId = localdrive_backup` | Backup completion alerts. |

The Settings toggle uses `notificationsEnabledProvider`, persisted as
`ld.notifications_enabled`. Turning it on requests OS notification permission and enables
change polling; turning it off cancels refresh work and gates all posting paths.

## Auto-backup settings
`BackupSettings` is stored as JSON under `ld.backup_settings`:
| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Master auto-backup switch. |
| `photos` | `true` | Include image assets. |
| `videos` | `true` | Include video assets. |
| `contacts` | `false` | Include a daily contacts vCard. |
| `wifiOnly` | `true` | Register background backup with unmetered-network constraint. |
| `driveUuid` / `driveLabel` | `null` | Destination drive. |
| `folder` | `Backup` | Base destination folder. |

`settings.runnable` is true only when enabled, destination is set, and at least one source is
selected.

## Backup engine
`BackupEngine` is pure of Riverpod so it can run in UI and background isolates. It:
- requests gallery/contact access through `MediaService`;
- enumerates the all-media album in pages of 100 for photos/videos;
- exports contacts once per day as `contacts-YYYY-MM-DD.vcf`;
- dedupes with `LocalDb.backup_ledger` unique `(instance_id, asset_id)`;
- uploads via tus `/api/upload` with metadata `filename`, `drive`, `path`;
- writes photos to `<folder>/Photos`, videos to `<folder>/Videos`, contacts to
  `<folder>/Contacts`;
- marks successful uploads in the ledger with remote drive/path.

## Foreground backup
`BackupRunner` powers **Back up now**. It validates destination/source, forces:
```text
Cookie: ld_view=user
```
then creates `BackupEngine` with live progress counts (`uploaded`, `skipped`, `failed`,
`current`). A successful run with uploaded items may post a backup notification.

## Headless/background backup
`runHeadlessBackup()` is the WorkManager backup entry point. It reads persisted settings,
active instance, saved instances, and secure token directly. It no-ops if anything is
missing or `settings.runnable` is false. Backup work is registered as:
| Constant | Value |
| --- | --- |
| `BgTasks.backup` | `com.sudiptab2100.localdrive_app.backup` |
| Period | 1 hour |
| Constraint | unmetered when `wifiOnly`, otherwise connected |

The headless upload client also forces `ld_view=user`, preserving the invariant that admins
back up personal device data to their own space rather than the whole share.

## iOS BGTask launch-handler registration (required)
On iOS every `BGTaskSchedulerPermittedIdentifiers` id must have a `BGTaskScheduler` launch
handler registered **before `application(_:didFinishLaunchingWithOptions:)` returns**, or the
first `BGTaskScheduler.submit()` aborts the process (native `SIGABRT` — a Dart `try/catch`
cannot catch it). Because this app uses Flutter's **UIScene lifecycle**
(`FlutterImplicitEngineDelegate`), plugins register *after* `didFinishLaunching` returns, so
`workmanager_apple` cannot register the handlers itself in time.

`ios/Runner/AppDelegate.swift` therefore registers a handler for every permitted id (read from
Info.plist) via `WorkmanagerPlugin.registerPeriodicTask(withIdentifier:)` and then calls
`WorkmanagerPlugin.registerLaunchHandlers()` for tasks persisted from a previous session. Keep
this in `didFinishLaunchingWithOptions`; removing it reintroduces the launch crash. If a new
BGTask id is added, add it to `BGTaskSchedulerPermittedIdentifiers` (the AppDelegate loop picks
it up automatically).

## iOS throttling
Info.plist declares `fetch` and `processing` background modes and permits both BGTask ids.
Actual iOS execution is OS-throttled and must be validated on a signed Xcode build, not on
this scaffold-only host.
