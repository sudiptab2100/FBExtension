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
2. resolves each instance's selected verified account and its per-account secure token;
3. reads a cursor scoped to the instance and server user ID;
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

## Account-owned auto-backup settings
`BackupSettings` is stored under `ld.backup_profile.<profileId>`, where profileId
is the JSON tuple `[instanceId, userId]`. Only the active server/account can prepare
or resume automatic backups. Switching users pauses the old account's work;
signing out cancels its queued work before removing credentials.

The old global `ld.backup_settings` record is retained for explicit import. It is
not silently assigned to the currently selected account. Imported settings remain
disabled until the user reviews the destination and enables automatic backup.

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Master auto-backup switch. |
| `photos` | `true` | Include image assets. |
| `videos` | `true` | Include video assets. |
| `contacts` | `false` | Include a daily contacts vCard. |
| `wifiOnly` | `true` | Require Wi-Fi/wired LAN during preparation; native transfers disallow cellular. |
| `chargingOnly` | `true` | Start automatic preparation only while charging, including on-open catch-up. |
| `driveUuid` / `driveLabel` | `null` | Destination drive. |
| `folder` | `Backup` | Base destination folder. |

`settings.runnable` is true only when enabled, destination is set, and at least one source is
selected.

## Durable backup pipeline
`BackupCoordinator` is usable without Riverpod in both UI and WorkManager engines.
Its LocalDb queue and ledger are scoped by verified account and destination, not
only instance/asset. Historical unowned ledger rows are retained rather than
credited to another account. A job keeps a stable ID, immutable source metadata,
tus resource/offset, staged path, retry state and transfer attempt identity.

Sources remain photos, videos, and a daily contacts vCard. Files land in
`<folder>/Photos`, `<folder>/Videos` and `<folder>/Contacts`. Permission dialogs are
foreground-only. A background worker checks existing grants and defers unavailable
media; denied permissions or an unavailable iCloud original are not a successful scan.

Both manual and automatic backup force:
```text
Cookie: ld_view=user
```
The backup destination picker uses that same personal scope even for an admin
viewing the whole share elsewhere. Picking a backup folder does not change the
file browser's view mode.

**Back up now** bypasses charging, but not Wi-Fi or authorization. Launch/resume and
foreground network/power changes trigger eligible catch-up, with persisted debounce
and retry backoff. A session generation and unique queue claims prevent old-account
or simultaneous foreground/headless work from being submitted twice.

## iOS native transfers
Background processing prepares a bounded batch in owned Application Support
staging. A native background URLSession uploads file-backed tus PATCH requests.
Transfers do not depend on keeping a Dart isolate alive. Source files remain
available until reconciliation; retries can stage the untransferred suffix.

Before retrying, recover the server job receipt and query HEAD for the actual tus
offset. LocalDrive-Master advertises `capabilities.backgroundBackupTus = 1` and
provides `GET /api/backup/uploads/:jobId`. This distinguishes an interrupted upload
from a completed file whose success response was lost. There is no second whole-file
upload protocol. Older servers use the foreground-only compatibility path and show
that a server update is required for recoverable native transfers.

The app-local native plugin is registered with both Flutter engines. It shares
stable sessions, persists nonsecret native completion events, and restores sessions
on launch. Dart reads events, commits idempotent queue/ledger changes, then
acknowledges them; events are not destructively drained before database commit.
Only confirmed server completion counts as backed up, never mere enqueueing.

The Backup screen shows actual queued/uploading/paused/failed states, last attempt
and last successful backup, including waiting-for-charging/Wi-Fi/server reasons.
Foreground catch-up resumes queued or paused jobs even when a full batch is already
pending; the coordinator, rather than the screen's timer, owns preparation limits.
Completion notifications are currently posted when the foreground reconciler
confirms a fully completed scan. A native transfer can finish while the app is
backgrounded without immediately displaying a completion notification.

## Headless/background backup
`runHeadlessBackup()` reads fresh preferences and the selected account through
`background_session.dart`, not the obsolete single-token-per-instance key.
Background feature tokens use iOS Keychain access after first unlock on this
device. The accessibility migration updates attributes atomically while unlocked;
rewriting a token value alone does not change its protection.

Scheduling is platform-specific:
| Constant | Value |
| --- | --- |
| `BgTasks.backup` | `com.sudiptab2100.localdrive_app.backup` |
| iOS | One-shot BGProcessingTask; hourly earliest-start hint, not an exact interval. |
| Android | Periodic WorkManager task, hourly interval. |
| iOS constraints | Connected network plus external power when chargingOnly. Wi-Fi is enforced separately. |
| Android constraints | Unmetered when wifiOnly, otherwise connected; charging when enabled. |

The iOS request is resubmitted at the start of a background wake, before expirable
work, and reconciled on lifecycle/settings/account changes. Scheduling failures
are visible. The pinned Apple workmanager implementation does not translate
`unmetered` into `requiresNetworkConnectivity`, so iOS scheduling uses `connected`.

## iOS BGTask launch-handler registration (required)
On iOS every `BGTaskSchedulerPermittedIdentifiers` id must have a `BGTaskScheduler` launch
handler registered **before `application(_:didFinishLaunchingWithOptions:)` returns**, or the
first `BGTaskScheduler.submit()` aborts the process (native `SIGABRT` — a Dart `try/catch`
cannot catch it). Because this app uses Flutter's **UIScene lifecycle**
(`FlutterImplicitEngineDelegate`), plugins register *after* `didFinishLaunching` returns, so
`workmanager_apple` cannot register the handlers itself in time.

AppDelegate therefore registers the backup identifier as processing and the refresh
identifier as refresh, before launch returns. It also sets Workmanager's plugin
registrant callback for the separate headless engine. Keep that early registration
and the existing UIScene/implicit-engine integration; removing either can reintroduce
a startup crash or missing-plugin failures.

## iOS limitations
iOS decides when background scanning runs. Background App Refresh restrictions,
Low Power Mode, permissions, and a device not yet unlocked after reboot can defer
work. The Mac must be awake/reachable and the external drive mounted.

Native transfers may continue while the screen is locked or after system termination.
**Force-quitting from the app switcher cancels them and prevents automatic relaunch
until LocalDrive is opened again.** A charging-only setting controls preparation/
handoff; already handed-off transfers may finish after unplugging.

Use a signed release on a physical iPhone to observe suspension and transfer recovery.
A debugger-triggered processing task exercises the handler, not iOS's natural scheduling.
