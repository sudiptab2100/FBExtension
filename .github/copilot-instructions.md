# LocalDrive-App — Copilot working brief

> Auto-loaded into every Copilot session. Keep it short; deep detail lives in
> [`docs/`](../docs/README.md). Read the relevant `docs/` page before changing an area.

## What this is
A **Flutter iOS/Android mobile client** for the sibling LocalDrive server product,
`../LocalDrive-Master` (Electron/React/TypeScript macOS app). This app does not embed a
server; it discovers or stores LAN LocalDrive instances, authenticates to the selected
instance, browses drives/files, uploads device content, receives change notifications, and
backs up through account-owned durable jobs. iOS uses BGProcessing plus native background
URLSession transfers; Android uses WorkManager and the Dart transport.

Changes to LocalDrive-Master server APIs that this app depends on must stay
**backward-compatible** and be documented in both KBs (`LocalDrive-App/docs/` and
`LocalDrive-Master/docs/`).

## Tech stack
- **Flutter stable / Dart 3** (`localdrive_app` package, Material 3).
- **State:** Riverpod 3.x `Notifier` / `NotifierProvider` with untyped `Ref` where used.
- **Routing:** `go_router` with connection/auth redirects in `lib/routing/router.dart`.
- **HTTP:** Dio, bearer JWT interceptor, `ld_view` admin-scope cookie, optional self-signed
  TLS trust. tus uploads use `tus_client` + `package:http`.
- **Storage:** `flutter_secure_storage` for per-instance/account JWTs, `shared_preferences`
  via `Prefs`, and schema-v3 `LocalDb` for backup jobs, ledger, leases, attempts and events.
- **Device services:** `nsd` mDNS discovery, `mobile_scanner` QR, `flutter_local_notifications`,
  `workmanager`, `photo_manager`, `flutter_contacts`, `file_picker`, `open_filex`,
  `share_plus`, `cached_network_image`.

## Repo/lib map (see `docs/project-structure.md`)
```
lib/main.dart              boot: Prefs, notifications, WorkManager, ProviderScope
lib/app.dart               MaterialApp.router, theme, long-lived liveEventsProvider
lib/core/config/           API paths, defaults, store keys, Material theme
lib/core/network/          Dio factory, SSE parser, API exception normalization
lib/core/storage/          Prefs, secure token store, sqflite LocalDb
lib/data/models/           JSON models matching server/app contracts
lib/data/repositories/     auth, connect, drives, files/search, admin REST wrappers
lib/data/services/         discovery, uploads, notifications, WorkManager, media, backup
lib/state/                 Riverpod providers/controllers for connection/session/settings/live/backup
lib/routing/router.dart    app routes and connection/session guards
lib/features/              connect, auth, drives, files, device, backup, settings, admin UI
```

## Golden-path commands
Every Flutter command on this host must be prefixed with the env script:
```bash
source ~/.localdrive_flutter_env.sh && flutter pub get
source ~/.localdrive_flutter_env.sh && flutter analyze
source ~/.localdrive_flutter_env.sh && flutter test
source ~/.localdrive_flutter_env.sh && flutter build apk --debug
```
- Android `compileSdk` is pinned to **36** in both Gradle files; do not revert it.
- Preserve the Workmanager Kotlin compatibility hook while AGP built-in Kotlin is disabled.
- `permission_handler` is pinned to `^11.3.1` to avoid the API-37 build break here.
- iOS is buildable on this Mac with Xcode 16.4; source the same environment script for
  Flutter/Xcode/CocoaPods commands. Preserve the pinned pre-iOS-26 plugin versions and
  configured signing team. Only a connected physical iPhone can validate background transfer.
- Direct Xcode builds produce `build/ios/Release-iphoneos/Runner.app`; the usual Flutter
  output can be stale. Verify the actual artifact and update in place, never uninstall.
- Let the app create its staging directories before copying fixtures: CoreDevice can leave
  root-owned parents that the app cannot write. Do not relax protection or reset data.

## Key invariants
- **Tokens are secrets:** JWTs live only in secure storage under
  `ld.token.<instanceId>::<username>` (the per-instance key is legacy migration only);
  never log bearer tokens, cookies, passwords, QR payloads with credentials, or cert details.
- **Instance isolation:** saved servers are `LdInstance` records keyed by
  `scheme://host:port`. View mode is per instance; tokens, backup state and polling cursors
  are per account. Backup profiles use the verified server user ID, not a guessed owner.
- **Durable backup:** only the active account submits work. Keep generation fences and
  pause/cancel before switching or deleting credentials. Preserve unowned legacy rows.
  Read native events, commit the SQLite ledger/queue transaction, then ACK.
- **Database opening:** both WAL and busy-timeout setters return rows; use `rawQuery`.
  Cover `LocalDb.open()`, not only mocked migrations. Never wipe storage to fix an error.
- **Policy:** charging-only and Wi-Fi-only default on; manual backup bypasses only charging.
  iOS scheduling is OS-controlled; force-quit prevents automatic relaunch until reopened.
- **Path/scope semantics mirror the server:** client paths are scope-relative POSIX paths.
  Do not invent absolute server paths or bypass LocalDrive-Master RBAC.
- **Drive access is opt-in:** non-admins request access; admins approve. `GET /api/drives`
  returns all registered drives annotated with `access`.
- **Admin view mode:** admins can send `ld_view=admin` (whole share) or `ld_view=user` (own
  space). Backups always force `ld_view=user`.
- **Networking is LAN-first:** discover `_localdrive._tcp` first and `_http._tcp` only when
  advertised as LocalDrive; validate candidates with `GET /api/health` before saving.
- **Self-signed TLS is explicit trust:** only use permissive certificate handling for an
  instance after user approval.
- **Server API compatibility:** additions consumed here (`_localdrive._tcp`,
  `/api/events/user`, `/api/changes`, `backgroundBackupTus`, backup receipts) must stay
  additive and documented. Bytes still use tus; offset equals length is not completion proof.

## Git
Remote: `github.com/sudiptab2100/LocalDrive-App`. Commit/push only when requested, on the
current branch; fetch and rebase onto its remote counterpart before pushing. Include:
`Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`

## Knowledge base index
Start at [`docs/README.md`](../docs/README.md). Key pages:
[architecture](../docs/architecture.md) ·
[project-structure](../docs/project-structure.md) ·
[api-integration](../docs/api-integration.md) ·
[connectivity-discovery](../docs/connectivity-discovery.md) ·
[notifications-backup](../docs/notifications-backup.md) ·
[permissions](../docs/permissions.md) ·
[state-management](../docs/state-management.md) ·
[build-run](../docs/build-run.md) ·
[features](../docs/features.md) ·
[conventions](../docs/conventions.md) ·
[glossary](../docs/glossary.md)
