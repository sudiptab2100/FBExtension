# State management

Riverpod owns app state; controllers persist durable state and repositories keep network calls thin.

## Provider style
The app uses Riverpod 3.x `Notifier`/`NotifierProvider` for mutable app state and
`FutureProvider`/`StreamProvider` for repository-backed data. Some providers use untyped
`Ref`, matching Riverpod 3 APIs in this codebase.

## Core providers
| Provider | File | State |
| --- | --- | --- |
| `prefsProvider` | `core_providers.dart` | Overridden `Prefs`; must be loaded before `runApp`. |
| `secureStoreProvider` | `core_providers.dart` | Secure per-instance JWT store. |
| `localDbProvider` | `core_providers.dart` | Lazy `LocalDb.open()` future. |

## Connection flow
`ConnectionController` owns `ConnectionState(instances, activeId)`.

| Action | Effect |
| --- | --- |
| `addOrUpdate(instance, activate)` | Merges by `instance.id`, preserves self-signed trust, optionally activates, writes prefs. |
| `setActive(id)` | Changes active server; router/session rebuild. |
| `remove(id)` | Removes saved server, clears active if needed, deletes secure token. |
| `markConnected(id)` | Updates `lastConnectedAt`. |

`activeInstanceProvider` selects `ConnectionState.active` for Dio/session/upload/backup.

## Session flow
`SessionController` rebuilds whenever `activeInstanceProvider` changes:
1. no active server → `unauthenticated`;
2. active server → load per-instance view mode and asynchronously read secure token;
3. no token → `unauthenticated`;
4. token exists → set token, call `/api/auth/me`, then authenticate or delete invalid token.

| Session field | Meaning |
| --- | --- |
| `status` | `loading`, `unauthenticated`, `pending`, `authenticated` (`pending` enum exists; pending register is currently shown via dialog/result). |
| `user` | Current `AppUser`. |
| `token` | In-memory active-instance JWT; persisted only in secure storage. |
| `viewMode` | Admin cookie value, default `admin`. |
| `effectiveViewMode` | Admins use chosen mode; normal users behave as `user`. |

401 responses call `handleUnauthorized()`, delete the active token, and route back to login.

## API providers
`dioProvider` rebuilds on active server changes. Token/view mode are read lazily from session
on each request, so login/logout/view-mode changes do not require rebuilding Dio. Repository
providers are one-line wrappers over this Dio.

`authHeadersProvider` rebuilds on session changes and is used outside Dio by:
- `CachedNetworkImage`/previews for thumbnails/raw URLs;
- `UploadService` for tus uploads.

## View-mode propagation
Admin view mode is stored per instance under `ld.view_mode.<instanceId>`. Changing it via
Settings or Drives toolbar updates `SessionController`, persists `Prefs`, and causes:
- Dio requests to send `Cookie: ld_view=<mode>`;
- `drivesListProvider` to refetch because it watches `effectiveViewMode`;
- `fileListProvider` families to refetch because they watch `effectiveViewMode`.

## Feature providers
| Provider | File | Behavior |
| --- | --- | --- |
| `discoveredInstancesProvider` | `discovery_service.dart` | Auto-dispose stream of mDNS results; stops discovery on dispose. |
| `_authConfigProvider` | `login_screen.dart` | Reads `/api/auth/config` to show/hide registration. |
| `drivesListProvider` | `drives_screen.dart` | Reads `/api/drives`; invalidated by SSE/access actions. |
| `fileListProvider(args)` | `file_browser_screen.dart` | Reads `/api/files/list`; family keyed by drive/path/hidden. |
| admin FutureProviders | `features/admin/*` | Dashboard/users/access/config/server status; invalidated after mutations. |
| `themeModeProvider` | `settings_controller.dart` | Persists `ThemeMode.system|light|dark`. |
| `notificationsEnabledProvider` | `settings_controller.dart` | Persists notification toggle and registers/cancels change polling. |
| `backupSettingsProvider` | `backup_controller.dart` | Persists `BackupSettings` and registers/cancels periodic backup. |
| `backupRunnerProvider` | `backup_controller.dart` | Foreground backup run progress. |

## Live events
`liveEventsProvider` is a `NotifierProvider<LiveEventsController,bool>`. It self-gates on
`session.isAuthenticated` and active instance. It cancels the stream on dispose/rebuild and
reconnects when auth or server state changes.

## Background isolate boundary
WorkManager code must not read Riverpod providers. `background_service.dart` and
`runHeadlessBackup()` reconstruct dependencies from persisted data: SharedPreferences,
secure storage, `buildDio()`, `UploadService`, `MediaService`, `LocalDb`.
