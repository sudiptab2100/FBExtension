# LocalDrive-App Knowledge Base

A concise engineer/AI reference for the Flutter mobile client of LocalDrive-Master.

> The always-loaded brief lives at
> [`.github/copilot-instructions.md`](../.github/copilot-instructions.md). This folder is
> the deeper reference it links to.

## What LocalDrive-App is
LocalDrive-App is a Flutter mobile client for LocalDrive-Master. It discovers LAN servers,
connects by QR/manual entry/saved instance, signs in with LocalDrive accounts, browses
opt-in drives, manages files, uploads device media/files/contacts, exposes an admin console
for admins, receives live/background notifications, and can periodically auto-back up device
photos, videos, and contacts.

## Reading order
1. [architecture.md](architecture.md) — runtime layers, data flow, Riverpod graph, Dio, isolates.
2. [project-structure.md](project-structure.md) — annotated `lib/` tree.
3. [api-integration.md](api-integration.md) — exact HTTP paths from `Api.*` constants.
4. [connectivity-discovery.md](connectivity-discovery.md) — mDNS, QR/manual connect, saved instances, TLS trust.
5. [notifications-backup.md](notifications-backup.md) — SSE, WorkManager polling, local notifications, auto-backup.
6. [permissions.md](permissions.md) — Android manifest and iOS Info.plist permissions.
7. [state-management.md](state-management.md) — Riverpod providers/controllers and state flow.
8. [build-run.md](build-run.md) — host commands and platform limitations.
9. [features.md](features.md) — user-facing features mapped to code.
10. [conventions.md](conventions.md) — implementation conventions and invariants.
11. [glossary.md](glossary.md) — key vocabulary.

## Fast facts
| Thing | Value |
| --- | --- |
| Package | `localdrive_app` |
| App id / Android namespace | `com.sudiptab2100.localdrive_app` |
| Flutter/Dart | Flutter stable, Dart SDK `^3.13.2` |
| State | `flutter_riverpod ^3.4.3` |
| Router | `go_router ^18.0.1` |
| HTTP | `dio ^5.11.1`, tus uploads via `tus_client ^1.0.2` |
| Default server ports | HTTP `4820`, HTTPS `4843` |
| Discovery services | `_localdrive._tcp`, `_http._tcp` filtered by name `LocalDrive` |
| Local stores | secure storage tokens, shared preferences, sqflite `localdrive.db` |
| Android minimum | API 26 |
| iOS scaffold target in repo | deployment target `15.0` in `ios/Runner.xcodeproj`; Info.plist has Local Network/BGTask entries |

## Keeping this KB accurate
When code changes behavior, update the affected page. The highest-value pages to keep in
sync with code are `api-integration.md`, `notifications-backup.md`, `state-management.md`,
and `permissions.md`. Keep server-facing contracts aligned with LocalDrive-Master's
`docs/http-api.md`.
