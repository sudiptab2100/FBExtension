# Glossary

Key terms used across LocalDrive-App and the LocalDrive-Master API.

| Term | Meaning |
| --- | --- |
| LocalDrive-App | The Flutter iOS/Android client. |
| LocalDrive-Master | The macOS Electron app hosting the HTTP/WebDAV server. |
| Instance | A server identified by `scheme://host:port`. |
| Active account | The selected authenticated user on the active instance; only this account prepares/resumes backup. |
| JWT | Authentication token stored per instance/username in Keychain or Keystore, never in backup tables. |
| Profile ID | JSON tuple `[instanceId, verifiedServerUserId]` identifying account-owned backup state. |
| Destination ID | JSON tuple of drive UUID and normalized backup folder within a profile. |
| Session generation | Persisted fence preventing stale work from submitting after account/server changes. |
| `Api.*` | Server path constants in `core/config/constants.dart`. |
| `ld_view` | Restrict-only admin scope cookie: `admin` for whole share or `user` for personal space. Backups always use `user`. |
| Drive access | Opt-in state: `granted`, `pending`, `denied`, or `none`. |
| Scope-relative path | POSIX path within the caller's permitted space, not an absolute server path. |
| mDNS / Bonjour | LAN discovery using `_localdrive._tcp` and filtered `_http._tcp`. |
| Health probe | `/api/health`, including optional server capability discovery. |
| Self-signed trust | Explicit approval for one saved server origin, not global TLS bypass. |
| tus | Resumable upload protocol at `/api/upload`; backup bytes use the same endpoint. |
| Backup receipt | Owner-scoped `/api/backup/uploads/:jobId` result proving finalization; offset equal to length alone is insufficient. |
| Backup job | Stable logical upload identity, account/destination/source and resumable state persisted in SQLite. |
| Attempt | One transport handoff for a job; interruption can create a new attempt without creating another logical backup. |
| Backup ledger | Account/destination/source-scoped successful backups; ambiguous legacy rows remain unowned. |
| Staging | Owned copies of source/suffix files retained until durable reconciliation permits cleanup. |
| Native journal | iOS OS-task identities and completion events, separate from the SQLite ledger. |
| ACK | Acknowledgement sent after committing a native event to SQLite. |
| BackupSnapshot | Queued/transferring/waiting/error/completed progress and persisted attempt/success history. |
| BGProcessing | iOS-granted preparation window, not continuous execution or an exact schedule. |
| Background URLSession | Native iOS transfer service for file-backed requests while Flutter is suspended. |
| WorkManager | Periodic Android scheduler; the Flutter Workmanager integration also exposes iOS BGTask APIs. |
| Headless backup | Backup entry point that reconstructs persisted context without Riverpod or a Flutter UI. |
| Foreground catch-up | Eligibility/reconciliation after launch, resume, or network/power changes. |
| SSE | Foreground `/api/events/user` stream for file/access/drive changes. |
| Changes cursor | Per-profile polling cursor under `ld.change_cursor.<profileId>`. |
| Destination picker | Selects a granted writable drive/folder; backup browsing forces personal scope. |
| Admin console | Mobile administration UI for stats, users, drive requests, settings and server control. |
