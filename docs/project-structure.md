# Project structure

The `lib/` tree separates Flutter UI, Riverpod state, REST repositories, platform services, and storage.

## Top-level tree
```text
lib/
  app.dart
  main.dart
  core/
    config/
    network/
    storage/
    utils/
  data/
    models/
    repositories/
    services/
  features/
    admin/
    auth/
    backup/
    connect/
    device/
    drives/
    files/
    settings/
    shell/
  routing/
  state/
  widgets/
```

## Root
| Path | Role |
| --- | --- |
| `main.dart` | Loads `Prefs`, initializes notifications/background services, enables polling/backup if persisted settings require it, then starts `ProviderScope`. |
| `app.dart` | Root `ConsumerWidget`; watches router, theme mode, and `liveEventsProvider`; renders `MaterialApp.router`. |

## `core/`
| Path | Role |
| --- | --- |
| `core/config/constants.dart` | Source of truth for API paths, default ports/org id, discovery names, preference keys, `ld_view`, notification channels, WorkManager ids. |
| `core/config/theme.dart` | Material 3 light/dark themes seeded with LocalDrive blue `0xFF2563EB`. |
| `core/network/api.dart` | `guard()` wrapper that maps Dio failures to `ApiException`. |
| `core/network/api_exception.dart` | User-presentable error, plus `pending`, `isNetwork`, and `isAuth` flags. |
| `core/network/dio_client.dart` | Dio factory with bearer, `ld_view`, TLS trust, and 401 handling interceptors. |
| `core/network/sse_client.dart` | Generic SSE line parser yielding `SseEvent(event,data)`. |
| `core/storage/prefs.dart` | SharedPreferences wrapper for instances, active id, view mode, theme, notifications, change cursors, JSON blobs. |
| `core/storage/secure_store.dart` | Per-instance JWT storage in Keychain/Keystore. |
| `core/storage/local_db.dart` | sqflite `backup_ledger` and `upload_queue`. |
| `core/utils/format.dart` | Human formatting for bytes/dates/relative times. |
| `core/utils/json.dart` | Defensive JSON coercion helpers. |

## `data/models/`
| Model | Contract |
| --- | --- |
| `ld_instance.dart` | App-only server identity (`scheme://host:port`), source (`manual`/`qr`/`discovered`), self-signed trust. |
| `server_status.dart` | LocalDrive-Master `ServerStatus` from health/dashboard. |
| `connect_info.dart` | `/api/connect` response (`urls`, `hostname`, `qr`, `addresses`, ports). |
| `user.dart` | `AppUser`, `UserRole`, `UserStatus`. |
| `drive_info.dart` | `DriveInfo` and opt-in `DriveAccess`. |
| `file_entry.dart` | `FileEntry` plus `SearchHit`. |
| `acl.dart` | Admin ACLs and `AdminUser`. |
| `access_request.dart` | Pending drive access approval shape. |
| `app_config.dart` | Admin-visible server config. |
| `backup_settings.dart` | Persisted auto-backup settings and `runnable` eligibility. |

## `data/repositories/`
| Repository | Calls |
| --- | --- |
| `auth_repository.dart` | `/api/auth/login`, `/register`, `/me`, `/config`, `/logout`. |
| `connect_repository.dart` | `/api/health`, `/api/connect`. |
| `drives_repository.dart` | `/api/drives`, request access, admin drive registration. |
| `files_repository.dart` | `/api/files/*`, `/api/search`, binary URL builders/download. |
| `admin_repository.dart` | Users/ACLs, access approvals, config, server lifecycle, dashboard stats. |

## `data/services/`
| Service | Role |
| --- | --- |
| `discovery_service.dart` | NSD mDNS browsing for `_localdrive._tcp` and filtered `_http._tcp`. |
| `upload_service.dart` | tus `/api/upload` client with auth metadata and optional self-signed TLS trust. |
| `notification_service.dart` | Local notification initialization, permission request, channel creation, posting. |
| `background_service.dart` | WorkManager dispatcher and registration for changes/backup tasks. |
| `media_service.dart` | Gallery albums/assets, contact permission/count/export vCard. |
| `backup_engine.dart` | Pure backup engine and headless WorkManager backup entry point. |

## `state/`
| File | Providers/controllers |
| --- | --- |
| `core_providers.dart` | `prefsProvider`, `secureStoreProvider`, `localDbProvider`. |
| `api_providers.dart` | `dioProvider`, `authHeadersProvider`, repository providers. |
| `connection_controller.dart` | Saved instances and active server selection. |
| `connect_controller.dart` | Candidate health probe and persistence. |
| `session_controller.dart` | Login/register/logout, token restore, 401 handling, admin view mode. |
| `settings_controller.dart` | Theme mode and notification toggle. |
| `live_events.dart` | Foreground `/api/events/user` subscription and provider invalidation. |
| `backup_controller.dart` | Persisted backup settings and foreground `Back up now` runner. |

## `features/`
| Folder | Screens |
| --- | --- |
| `connect/` | Server chooser (`ConnectScreen`) and QR scanner (`QrScanScreen`). |
| `auth/` | Splash/session retry screen and login/register form. |
| `shell/` | `HomeShell` bottom navigation: Drives, Device, Backup, Settings. |
| `drives/` | Drive list, access request action, admin view-mode toggle. |
| `files/` | File browser, search, thumbnails, upload progress, preview/download/share. |
| `device/` | Device-source upload tab, photo/video grid, destination picker. |
| `backup/` | Auto-backup configuration and foreground run UI. |
| `settings/` | Account/server/theme/notifications/admin entry/sign-out. |
| `admin/` | Dashboard, users, access requests, config, server control. |

## `routing/` and `widgets/`
| Path | Role |
| --- | --- |
| `routing/router.dart` | Route constants, guarded `GoRouter`, feature route builders. |
| `widgets/status_views.dart` | Reusable loading/error/empty states. |

## Tests
| Test file | Covers |
| --- | --- |
| `test/ld_instance_test.dart` | URL parsing, default ports, JSON round-trip for `LdInstance`. |
| `test/backup_settings_test.dart` | Safe defaults, `runnable`, JSON defaults/round-trip. |
| `test/auth_repository_test.dart` | Login parsing, pending registration, 401/error mapping. |
| `test/models_test.dart` | `FileEntry`, `SearchHit`, `DriveInfo`, `AppUser`, `AppConfig` parsing. |
| `test/files_repository_url_test.dart` | Formatting and binary URL builders for raw/thumb/zip/download. |
