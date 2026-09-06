# Architecture

LocalDrive-App is a Flutter client layered around Riverpod state, Dio repositories, and platform services.

## Runtime layers
| Layer | Code | Responsibility |
| --- | --- | --- |
| Boot/root | `lib/main.dart`, `lib/app.dart` | Initialize Flutter, load `Prefs`, initialize notifications/WorkManager, keep live SSE mounted, render `MaterialApp.router`. |
| Routing | `lib/routing/router.dart` | `go_router` routes plus redirects for no active server, session restore, unauthenticated login, and authenticated home. |
| State | `lib/state/*` | Riverpod controllers for connection, session, settings, live events, backup settings/runs. |
| Repositories | `lib/data/repositories/*` | Thin REST wrappers over LocalDrive-Master HTTP API. |
| Network | `lib/core/network/*` | Dio construction, auth/view-mode interceptors, SSE parsing, normalized `ApiException`. |
| Platform services | `lib/data/services/*` | mDNS, tus uploads, local notifications, WorkManager, gallery/contacts, backup engine. |
| UI features | `lib/features/*` | Connect/auth shell, drives/files/device/backup/settings/admin screens. |
| Storage | `lib/core/storage/*` | Secure JWT store, shared preferences, sqflite backup ledger/upload queue. |

## Data flow
1. `main()` loads `Prefs` before first frame and overrides `prefsProvider`.
2. `ConnectionController` reads saved `LdInstance`s and the active instance id.
3. `SessionController` reacts to the active instance, reads its secure token, then probes
   `GET /api/auth/me` to restore the user.
4. `routerProvider` listens to connection/session state and redirects:
   `connect → splash/login → home`.
5. Feature screens watch repository-backed providers (`drivesListProvider`,
   `fileListProvider`, admin providers). Repositories call Dio using `Api.*` paths.
6. Dio injects `Authorization: Bearer <token>` and, for admins, `Cookie: ld_view=<mode>`.
7. Server responses are parsed into models; mutations invalidate affected FutureProviders.

## Riverpod graph (core)
| Provider | Depends on | Used by |
| --- | --- | --- |
| `prefsProvider` | `Prefs` override in `main()` | connection/session/settings/backup/background cursors. |
| `secureStoreProvider` | `FlutterSecureStorage` | per-instance JWT read/write/delete. |
| `connectionControllerProvider` | `Prefs` | active server list, router redirects, Dio base URL. |
| `activeInstanceProvider` | connection state | Dio, connect/session/upload/backup. |
| `sessionControllerProvider` | active instance, secure store, auth repo, prefs | auth restore, login/register/logout, admin view mode. |
| `dioProvider` | active instance, session token/view mode | all REST repositories. |
| `authHeadersProvider` | session state | thumbnails/previews/uploads outside Dio. |
| `liveEventsProvider` | active instance, session, Dio | app-wide `/api/events/user` subscription. |
| `backupSettingsProvider` | `Prefs` | Backup tab and WorkManager backup registration. |
| `backupRunnerProvider` | backup settings, upload/media/db | foreground backup run. |

## Dio client
`buildDio()` in `lib/core/network/dio_client.dart` binds one `Dio` instance to a server
base URL. It configures:
- connect/receive/send timeouts;
- bearer auth from a lazy token provider;
- `ld_view` cookie from a lazy admin view-mode provider;
- optional `IOHttpClientAdapter.badCertificateCallback` for user-approved self-signed TLS;
- a 401 callback that calls `SessionController.handleUnauthorized()`.

Binary endpoints use the same Dio instance for downloads. Image thumbnails/previews and tus
uploads need explicit headers from `authHeadersProvider` because they run outside normal Dio
JSON calls.

## SSE and isolates
Foreground live events run in the UI isolate: `LocalDriveApp` watches `liveEventsProvider`,
which opens a streamed Dio request to `/api/events/user` while authenticated.

Background work runs in a WorkManager background isolate through `backgroundDispatcher()` in
`background_service.dart`. That isolate must not touch Riverpod; it reads
`SharedPreferences` and `FlutterSecureStorage` directly, reconstructs `LdInstance`s, builds
throwaway Dio/upload clients, and calls either `_pollChanges()` or `runHeadlessBackup()`.

## Local database
`LocalDb.open()` creates `localdrive.db` with:
| Table | Purpose |
| --- | --- |
| `backup_ledger` | Dedupe records keyed by unique `(instance_id, asset_id)`. |
| `upload_queue` | Future-ready persistent queue with tus URL/status fields; current UI uploads run immediately. |

## App lifecycle notes
- Notifications and WorkManager initialization are best-effort and never block startup.
- WorkManager change polling is registered only when notifications are enabled.
- Backup periodic work is registered only when `BackupSettings.runnable` is true.
- Admin backups force `ld_view=user` so device data lands in the admin's own space.
