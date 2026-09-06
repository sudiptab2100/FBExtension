# Glossary

Key terms used across LocalDrive-App and the LocalDrive-Master API.

| Term | Meaning |
| --- | --- |
| LocalDrive-App | This Flutter iOS/Android client. |
| LocalDrive-Master | The Electron/React/TypeScript macOS app that hosts the HTTP/WebDAV server. |
| Instance | A saved/discovered LocalDrive server (`LdInstance`) identified by `scheme://host:port`. |
| Active instance | The selected server that drives auth, Dio base URL, uploads, polling, and backup. |
| Base URL | `http://host:4820` or `https://host:4843` for one instance. |
| `Api.*` | Dart constants in `core/config/constants.dart` for server paths. |
| Bearer token / JWT | Per-instance auth token returned by `/api/auth/login`, stored in secure storage. |
| `ld_view` | Server cookie used by admins: `admin` = whole share, `user` = own userspace. |
| View mode | App state controlling the `ld_view` cookie for admins. |
| Drive UUID | Server identifier passed as `drive` to drive/file/upload APIs. |
| Drive access | Opt-in state: `granted`, `pending`, `denied`, or `none`. |
| Scope-relative path | POSIX path as seen by the current user/view mode; not an absolute server path. |
| mDNS / Bonjour | LAN service discovery used by `_localdrive._tcp` and `_http._tcp`. |
| QR connect | Scanning a server base URL with `mobile_scanner`. |
| Health probe | `GET /api/health`, used to verify a candidate server before saving. |
| Self-signed trust | Per-instance approval that lets Dio/tus accept the server's local certificate. |
| Dio | HTTP client used for JSON requests, downloads, and SSE stream creation. |
| tus | Resumable upload protocol used at `/api/upload`. |
| SSE | Server-Sent Events; foreground stream from `/api/events/user`. |
| Changes feed | Background polling endpoint `/api/changes?since=<cursor>`. |
| Cursor | Per-instance timestamp token stored as `ld.change_cursor.<id>` for incremental polling. |
| WorkManager | Background task scheduler used for polling and backup. |
| Background isolate | Separate Dart execution context for WorkManager; cannot use Riverpod. |
| Local notification | OS notification posted through `flutter_local_notifications`. |
| BackupSettings | Persisted JSON controlling automatic backup sources/destination/network gate. |
| Backup ledger | sqflite table deduping uploaded assets by `(instance_id, asset_id)`. |
| Headless backup | WorkManager-triggered backup path that reconstructs state from storage. |
| Destination picker | UI for choosing an online, granted, writable drive/folder for uploads. |
| Admin console | Mobile admin screens for stats, users, access requests, config, and server control. |
| Scaffold-only iOS | iOS project files exist, but this host lacks full Xcode/signing validation. |
