# Conventions

These conventions keep the Flutter client safe, predictable, and aligned with LocalDrive-Master.

## Dart and imports
- Package name is `localdrive_app`; tests import app code with `package:localdrive_app/...`.
- Use `flutter_lints` from `analysis_options.yaml`; `android/**`, `ios/**`, and `build/**`
  are excluded from Dart analysis.
- Keep code organized by existing layers: UI in `features/`, state in `state/`, REST calls in
  `data/repositories/`, platform integration in `data/services/`.
- Prefer small model/repository/service classes over network code in widgets.

## API constants
- Add or change server paths only in `lib/core/config/constants.dart`.
- Keep `Api.*` names and docs synchronized with LocalDrive-Master `docs/http-api.md`.
- Do not invent endpoints in UI code; route all HTTP calls through repositories or services.

## Auth and secrets
- JWTs belong in `SecureStore` only (`ld.token.<instanceId>::<username>`).
  The old per-instance key is migration-only. Never infer ownership of legacy backup rows.
- Never log bearer tokens, cookies, passwords, QR values containing credentials, or raw certs.
- `Prefs` is for non-secret settings only: instances, active id, view mode, theme,
  notification flag, change cursors, backup settings.
- Backup profiles and change cursors are account-owned. Preserve generation fencing and
  pause/cancel before switching accounts or deleting credentials.

## Paths and scope
- Treat `drive` as a server UUID and `path` as a scope-relative POSIX path.
- Never construct absolute server filesystem paths in the mobile app.
- Admin view mode is only a narrowing/widening request to the server through `ld_view`; server
  RBAC remains authoritative.
- Backups must force `ld_view=user` so admin device backups land in the admin's own space.

## Networking
- Validate new instances with `GET /api/health` before saving.
- Use Dio for JSON and binary downloads; use `authHeadersProvider` for consumers outside Dio.
- Self-signed TLS bypass is allowed only when a saved `LdInstance.trustSelfSigned` is true.
- Keep server additions backward-compatible: `_localdrive._tcp`, `/api/events/user`,
  `/api/changes`, bearer-auth SSE.

## Riverpod
- Controllers persist their own durable state before/after updating Riverpod state as needed.
- Repository-backed data uses providers and invalidation after mutations.
- `SessionController` owns active-instance auth; do not store session state in widgets.
- Background isolate code must not access Riverpod. Rebuild dependencies from persisted state.

## UI patterns
- Material 3 theme comes from `AppTheme`; avoid ad-hoc global colors except semantic status
  colors where already used.
- Use existing `LoadingView`, `ErrorView`, and `EmptyView` for common states.
- Prefer guarded actions that show `ApiException.message` in a `SnackBar` and invalidate the
  affected provider on success.
- Use `DestinationChoice`/`showDestinationPicker()` for upload destinations to preserve drive
  grant/write filtering.

## Build rules
- Prefix Flutter commands with `source ~/.localdrive_flutter_env.sh &&` on this host.
- Keep Android compile SDK pinned to 36 unless the local platform/tooling issue is resolved.
- Preserve iOS signing and the pinned Xcode-compatible plugins. A build or simulator does
  not establish physical background behavior; use an unlocked physical iPhone.
- Keep build outputs, diagnostic credentials and staging fixtures out of Git.

## Backup persistence
- `LocalDb.open()` sets WAL and busy timeout with `rawQuery`: these pragmas return rows
  and cannot use Darwin sqflite's non-query `execute` path. Exercise opening in regressions.
- Extend the versioned database without dropping queues or assigning unowned history to
  the active user. Jobs capture their original account, destination and source identity.
- Reconcile server receipts before crediting completion. Read native events, commit the
  queue/ledger transaction, then ACK; do not discard staging before reconciliation.
- Charging-only/Wi-Fi-only default on. Manual backup bypasses charging, not authorization
  or network policy. Waiting, queued and partially failed work must not become success.

## Documentation
- Update this KB when behavior changes.
- If LocalDrive-Master's API changes for this app, update both repos' docs.
- Prefer durable contracts and invariants over volatile line numbers.
