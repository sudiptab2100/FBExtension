# API integration

The app consumes LocalDrive-Master exclusively through HTTP/SSE/tus paths defined in `lib/core/config/constants.dart`.

## Client rules
- Base URL comes from the active `LdInstance.baseUrl` (`scheme://host:port`).
- JSON calls use `dioProvider` and repository wrappers.
- Auth uses `Authorization: Bearer <token>` from secure storage.
- Ordinary admin browsing uses `Cookie: ld_view=admin|user`; normal browsing needs no
  scope cookie. Backup requests explicitly force `ld_view=user` for every account.
- Self-signed TLS trust is per saved instance (`trustSelfSigned`) and only after user approval.
- Client paths are server scope-relative POSIX paths; `drive` is a drive UUID.

## Auth — `AuthRepository`
| `Api.*` | Path | Method | Purpose |
| --- | --- | --- | --- |
| `Api.login` | `/api/auth/login` | POST | Body `{username,password}`; returns `{token,user}`. Token is stored per instance/account. |
| `Api.register` | `/api/auth/register` | POST | May return `{pending:true,message}` or `{token,user}` if auto-approved. |
| `Api.logout` | `/api/auth/logout` | POST | Server logout endpoint; local account logout stops owned backup before deleting credentials. |
| `Api.me` | `/api/auth/me` | GET | Session restore; a delayed 401 must not invalidate a replacement session. |
| `Api.authConfig` | `/api/auth/config` | GET | Public registration flag for showing create-account UI. |

Pending accounts are surfaced by login/register flows and cannot access the app shell.

## Drives — `DrivesRepository`
| `Api.*` | Path | Method | Purpose |
| --- | --- | --- | --- |
| `Api.drives` | `/api/drives` | GET | All registered drives annotated with `access`. |
| `Api.drivesRequestAccess` | `/api/drives/request-access` | POST | Non-admin request body `{uuid}`; returns `access`. |
| `Api.drivesAll` | `/api/drives/all` | GET | Admin-only detected/registered drive inventory. |
| `Api.drivesRegister` | `/api/drives/register` | POST | Admin registers detected drive `{uuid}`. |
| `Api.drivesUnregister` | `/api/drives/unregister` | POST | Admin unregisters drive `{uuid}`. |
| `Api.drivesRegisterFolder` | `/api/drives/register-folder` | POST | Admin registers absolute server folder `{path}`. |

The access model is opt-in: non-admins see drives but must be `granted` before opening or uploading.

## Files and search — `FilesRepository`
| `Api.*` | Path | Method | Purpose |
| --- | --- | --- | --- |
| `Api.filesList` | `/api/files/list` | GET | Query `drive`, `path`, optional `hidden=1`; returns `entries`. |
| `Api.filesMkdir` | `/api/files/mkdir` | POST | `{drive,path,name}`. |
| `Api.filesRename` | `/api/files/rename` | POST | `{drive,path,newName}`. |
| `Api.filesMove` | `/api/files/move` | POST | `{drive,sources,dest}`. |
| `Api.filesCopy` | `/api/files/copy` | POST | `{drive,sources,dest}`. |
| `Api.filesDelete` | `/api/files/delete` | POST | `{drive,paths}`. |
| `Api.filesDownload` | `/api/files/download` | GET | Download stream; also used by `downloadToFile()`. |
| `Api.filesRaw` | `/api/files/raw` | GET | Inline preview URL for images/videos. |
| `Api.filesZip` | `/api/files/zip` | GET | ZIP URL; `paths` query is newline-joined. |
| `Api.filesThumb` | `/api/files/thumb` | GET | Thumbnail URL for `FileThumbnail`. |
| `Api.search` | `/api/search` | GET | Query `q`, optional `drive`, optional `hidden=1`; returns hits. |

The file browser supports list/grid display, hidden toggle, sort, mkdir, rename, move, copy,
delete, upload, preview, download, open, and share.

## Uploads — `UploadService`
| `Api.*` | Path | Protocol | Metadata |
| --- | --- | --- | --- |
| `Api.upload` | `/api/upload` | tus | `filename`, `drive`, `path` |

`tus_client` does not use Dio, so `UploadService` builds its own headers from
`authHeadersProvider`. For self-signed instances it uses a custom `IOClient` with permissive
certificate callback only when the instance has been trusted.

### Recoverable native backup
The iOS backup coordinator retains tus but hands file-backed PATCH transfers to
background URLSession. Preparation/retry uses POST and HEAD while an execution
window is available. All backup requests explicitly use `ld_view=user`.

Servers supporting durable recovery advertise:
```json
{"capabilities":{"backgroundBackupTus":1}}
```
in the existing `/api/health` response. Creation adds `backupJobId` and
`backupSha256` to the normal tus metadata. A stable job ID recovers the same upload
instead of creating duplicates after a lost response.

`GET /api/backup/uploads/:jobId` is authenticated and owner-scoped. It returns
uploading/finalizing/complete/failed status, tus resource URL, content identity and
actual destination. A complete receipt proves finalization even after the tus
sidecar has been removed. An unfinished resource still uses HEAD for its offset.
Duplicate creation returns 409 and is reconciled through this status endpoint.
Recovery checks current access and must not overwrite unrelated same-named files.
Completed backup HEAD/PATCH requests return 410 and require receipt recovery.
Validate immutable job/content/destination identity; an offset equal to the file
length is not completion proof. Backup authentication is bearer-only and must not
fall back to another account's cookie.

Older servers remain compatible with foreground uploads; the app explicitly
requests a server update for recoverable native background backup.

## Admin — `AdminRepository`
| `Api.*` | Path | Method(s) | Purpose |
| --- | --- | --- | --- |
| `Api.stats` | `/api/stats` | GET | Admin dashboard metrics and server status. |
| `Api.activity` | `/api/stats/activity` | constant only | Defined in constants; no current repository call. |
| `Api.users` | `/api/users` | GET/POST/DELETE subpaths | List/create/delete users, approve pending users, password/role updates. |
| `Api.userAcls` | `/api/users/acls` | POST/DELETE subpaths | Upsert/remove ACLs; model exists, UI summarizes grants. |
| `Api.access` | `/api/access` | GET/POST subpaths | List, approve, deny drive access requests. |
| `Api.config` | `/api/config` | GET/PATCH | Registration, approvals, ports, host, HTTPS, share root name. |
| `Api.serverStart` | `/api/server/start` | POST | Start server. |
| `Api.serverStop` | `/api/server/stop` | POST | Stop server; may disconnect the app. |
| `Api.serverRestart` | `/api/server/restart` | POST | Restart server; may disconnect the app briefly. |

Admin-only screens are reachable from Settings/Admin console and from the Drives toolbar for admins.

## SSE and changes
| `Api.*` | Path | Used by | Purpose |
| --- | --- | --- | --- |
| `Api.events` | `/api/events` | constant only in app code | Admin-wide SSE path; current mobile live controller uses user-scoped SSE. |
| `Api.eventsUser` | `/api/events/user` | `LiveEventsController` | Foreground user-scoped SSE with bearer auth. |
| `Api.changes` | `/api/changes` | WorkManager `_pollChanges()` | Background incremental polling with `since=<cursor>`. |

`filesChanged` invalidates file lists and may post a notification. `accessChanged` and
`drivesChanged` invalidate the drive list. Background polling stores cursors under
`ld.change_cursor.<profileId>`, with profileId the instance/server-user-ID tuple.

## Utility/connectivity
| `Api.*` | Path | Method | Purpose |
| --- | --- | --- | --- |
| `Api.health` | `/api/health` | GET | Public validation probe; requires `{ok:true,status}`. |
| `Api.cert` | `/api/cert` | GET | Constant for server CA download; no current UI flow reads it directly. |
| `Api.connect` | `/api/connect` | GET | Authenticated server connection info model. |

## Server additions consumed
LocalDrive-App depends on LocalDrive-Master additions that must remain backward-compatible:
- `_localdrive._tcp` mDNS advertisement with TXT metadata (`path`, `api`, `https`, `httpsPort`).
- `GET /api/events/user` user-scoped SSE with bearer/cookie auth.
- `GET /api/changes?since=` compact changes feed returning `{changes,cursor}`.
- Optional `capabilities.backgroundBackupTus` and owner-scoped
  `GET /api/backup/uploads/:jobId` receipts for native backup recovery.
- Bearer auth support on all routes, including SSE.
