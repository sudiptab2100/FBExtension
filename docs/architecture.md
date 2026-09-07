# Architecture

LocalDrive-App is a Flutter client layered around Riverpod state, HTTP repositories,
durable account-owned storage, and platform services. The server remains in the
separate LocalDrive-Master repository.

## Runtime layers
| Layer | Code | Responsibility |
| --- | --- | --- |
| Boot/root | `lib/main.dart`, `lib/app.dart` | Initialize services, mount routing/SSE, observe lifecycle and power/network changes, reconcile scheduling and catch-up. |
| Routing | `lib/routing/router.dart` | Redirect between server selection, session restore, login and authenticated home. |
| State | `lib/state/*` | Active server/account, settings, live events, backup preparation and persisted progress. |
| Repositories | `lib/data/repositories/*` | Thin REST wrappers over LocalDrive-Master. |
| Network | `lib/core/network/*` | Dio, scoped authentication/view mode, SSE parsing and normalized failures. |
| Backup services | `lib/data/services/backup_*.dart` | Eligibility, owned staging, durable jobs, tus recovery and reconciliation. |
| Native iOS | `ios/Runner/BackgroundUpload*.swift`, `AppDelegate.swift` | Stable background URLSessions, protected staging/journal, BGTask registration and headless plugins. |
| UI | `lib/features/*` | Connect/auth, drives/files/device/backup/settings/admin surfaces. |
| Storage | `lib/core/storage/*` | Secure account tokens, preferences and schema-v3 sqflite jobs/ledger. |

## Data flow
1. `main()` loads `Prefs` and overrides `prefsProvider`.
2. `ConnectionController` resolves the selected saved server.
3. `SessionController` reads the selected account's secure token, verifies `/api/auth/me`,
   and persists the server user ID. Authentication changes are serialized and fenced.
4. The router selects `connect -> splash/login -> home`.
5. Feature providers call repositories using the active server and account.
6. Dio adds the authorization header and current admin browsing scope. Backups use a
   captured identity and force `ld_view=user`, independent of the file browser's view.
7. Successful mutations invalidate the appropriate providers. Account switches pause
   old-account backup before replacing credentials or submitting new-account work.

## Riverpod graph
| Provider | Depends on | Used by |
| --- | --- | --- |
| `prefsProvider` | Boot override | Saved servers/accounts, settings, generation fences and cursors. |
| `secureStoreProvider` | `FlutterSecureStorage` | Per-account Keychain/Keystore tokens. |
| `localDbProvider` | `LocalDb.open()` | Lazy shared database opening and backup persistence. |
| `activeInstanceProvider` | Connection state | Routing, HTTP and account selection. |
| `sessionControllerProvider` | Active server, secure store, preferences | Restore/login/switch/logout and view mode. |
| `dioProvider` | Server and current session | Ordinary REST repositories. |
| `authHeadersProvider` | Session | Thumbnails/previews and ordinary uploads. |
| `liveEventsProvider` | Server, session and Dio | User-scoped SSE subscription. |
| `backupSettingsProvider` | Selected verified account and preferences | Account-owned configuration and scheduling. |
| `backupCoordinatorProvider` | Local database and platform services | Durable preparation, transfer and reconciliation. |
| `backupRunnerProvider` | Captured context, coordinator and settings | Manual/automatic catch-up and visible progress. |

## Network and authentication
`buildDio()` configures timeouts, lazy authorization/view-mode headers, and explicitly
approved per-instance self-signed TLS. A delayed 401 from an old token must not evict
a replacement session. Public login/registration cannot borrow another account's token.

Ordinary file uploads retain `UploadService` and tus. Recoverable backups instead use
`BackupTusService` to create/recover a stable job, obtain the authoritative offset, and
verify the owner-scoped server receipt. Native upload URLs must stay on the approved
origin and canonical nonredirecting tus endpoint.

## Background execution
Foreground SSE stays in the UI isolate. WorkManager dispatches refresh/backup through
`background_service.dart` without Riverpod; headless code reloads preferences and
resolves the selected account's current secure token through `background_session.dart`.

iOS registers BGProcessing for preparation, resubmits one-shot work before it can
expire, and hands staged suffix files to native background URLSession. Native events
survive Flutter suspension and are read non-destructively: commit the SQLite
queue/ledger update before ACK. Android retains periodic WorkManager scheduling and
the Dart transfer path. Foreground launch/resume and network/power changes provide
catch-up on both platforms.

Preparation requires the configured network/charging policy, permissions, active
account and destination access. Manual backup bypasses charging only. iOS controls
execution windows, and force-quit prevents automatic relaunch until reopen.

## Local database
`LocalDb.open()` configures WAL and a 5000 ms busy timeout before additive migration to
schema version 3. Both setters return rows and use `rawQuery` on Darwin.

| Table | Purpose |
| --- | --- |
| `backup_ledger` | Owned successes deduped by profile, destination and source; legacy unowned rows remain separate. |
| `upload_queue` | Durable logical jobs, immutable ownership/source, staged paths, tus offsets and retry state. |
| `backup_locks` | Transactional leases coordinating foreground/headless work. |
| `backup_profile_state` | Destination/source scan state, last attempt/success and waiting/error status. |
| `backup_attempts` | Per-attempt transport identity and outcome. |
| `backup_native_events` | Idempotent native-event commits before acknowledgement. |

Native iOS owns OS task identities/events, not the logical ledger. Its journal and
staging use protected app-owned directories; credentials remain only in secure storage
and transport requests. Do not reset the database or skip account-transition guards
to hide a storage error.

See [state-management.md](state-management.md), [notifications-backup.md](notifications-backup.md)
and [api-integration.md](api-integration.md) for the detailed contracts.
