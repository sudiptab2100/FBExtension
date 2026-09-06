# Connectivity and discovery

The connect flow discovers, validates, saves, and selects LocalDrive-Master instances on the LAN.

## Instance model
`LdInstance` is app-only state:
| Field | Meaning |
| --- | --- |
| `scheme` | `http` or `https`. |
| `host` | IPv4 address, hostname, or `.local` name. |
| `port` | Defaults to `4820` for HTTP, `4843` for HTTPS. |
| `id` | Stable `scheme://host:port`; used for dedupe and per-instance storage. |
| `name` | Friendly label shown in the UI. |
| `source` | `manual`, `qr`, or `discovered`. |
| `hostname` | Advertised hostname when known. |
| `trustSelfSigned` | User-approved per-instance TLS bypass for local self-signed certs. |

Saved instances live in `Prefs` under `ld.instances`; active id lives under
`ld.active_instance`. Tokens are separate secure-storage entries keyed by the same id.

## mDNS discovery
`DiscoveryService` browses two Bonjour service types:
| Service | Code constant | Rule |
| --- | --- | --- |
| Dedicated LocalDrive | `Discovery.serviceType = _localdrive._tcp` | Preferred. Newer LocalDrive-Master advertises this. |
| Generic HTTP | `Discovery.httpServiceType = _http._tcp` | Accepted only when service name contains `LocalDrive`. |

Discovery uses `nsd.startDiscovery(..., ipLookupType: v4)`. It prefers a resolved IPv4
address, falls back to `s.host`, builds an HTTP `LdInstance`, and de-duplicates by id.
Discovery is best-effort: failures are caught, and the stream simply yields no servers.

`multicast_dns` is present in `pubspec.yaml`, but the current implementation uses `nsd`.

## Connect screen
`ConnectScreen` shows:
1. saved servers from `ConnectionController`;
2. live LAN discovery from `discoveredInstancesProvider`;
3. QR scan entry;
4. manual host/URL entry with optional HTTPS.

Selecting a saved server only sets it active; selecting a new discovered/manual candidate
calls `ConnectController.connect()`, which validates before saving.

## QR scan
`QrScanScreen` uses `mobile_scanner`. It expects the QR payload to parse as a LocalDrive
base URL through `LdInstance.tryParse(raw, source: InstanceSource.qr)`, then probes and
saves it. Invalid QR payloads are ignored.

## Manual entry
Manual entry accepts either a full URL or host/port fields:
- missing scheme defaults to HTTP;
- missing HTTP port defaults to `4820`;
- missing HTTPS port defaults to `4843`;
- `.local` hosts populate `hostname`.

## Health validation
`ConnectController.probe()` builds a throwaway unauthenticated Dio client and calls
`ConnectRepository.health()`:
```text
GET /api/health
```
The response must contain `ok: true` and a `status` object parseable as `ServerStatus`.
Only then does the controller persist the instance and optionally activate it.

## Self-signed TLS trust
For HTTPS candidates, a certificate failure is reported as a network-style `ApiException`.
`ConnectScreen` then offers an explicit **Trust & connect** dialog. Accepting retries with
`trustSelfSigned: true`, and the saved instance carries that trust bit. Dio and tus both use
permissive certificate callbacks only for trusted instances.

Known limitation: the app does not currently install the LocalDrive CA from `/api/cert`; it
stores an app-local trust decision for that instance instead.

## Switching/removing servers
- Settings → **Switch server** clears the active id but keeps saved server credentials.
- Saved server delete removes the instance and deletes its secure token.
- Switching active instances rebuilds `SessionController`, causing token restore for the new
  instance and router redirection as needed.
