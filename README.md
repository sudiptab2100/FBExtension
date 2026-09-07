# LocalDrive App

A native Flutter client for the private Wi-Fi/LAN storage server
[LocalDrive-Master](https://github.com/sudiptab2100/LocalDrive-Master).
Your Mac shares an external drive or folder; this iOS/Android app connects to it
without requiring third-party cloud storage.

## Features

- Discover local servers, scan connection QR codes, or save HTTP/HTTPS addresses.
  Self-signed HTTPS requires explicit trust for the selected server.
- Keep multiple accounts signed in and switch between them without mixing their
  credentials, backup destinations, queues, or history.
- Request access to shared drives, browse private folders, search, preview,
  upload, download, and manage files.
- Upload photos, videos, documents, and contacts; configure account-owned
  automatic photo/video and daily contacts backup.
- Resume queued backup jobs using durable local state and server completion
  receipts. iOS uses native background URLSession transfers; Android uses
  WorkManager scheduling and the Dart upload transport.
- Receive live/background change notifications and use the mobile admin
  console when signed in as an administrator.

## Connect and back up

1. Start LocalDrive-Master on your Mac and register the storage to share.
2. Put the phone/tablet and Mac on the same reachable network. Use discovery,
   QR scanning, or a manual URL; default ports are HTTP `4820` and HTTPS `4843`.
3. Sign in. Non-admin users request access to each drive and wait for approval.
4. In **Backup**, choose that account's destination and sources, grant the
   required permissions, and enable automatic backup or select **Back up now**.

Automatic backup is off until configured. Wi-Fi-only and charging-only preparation
are enabled by default. **Back up now** bypasses charging, but not Wi-Fi,
authentication, or drive access. Backups always use the account's private space,
including for administrators. Switching accounts pauses the previous account's
work rather than redirecting it.

### Background limits

iOS controls when new media can be scanned; it does not allow continuous app
execution or guarantee an exact schedule. Prepared native transfers can continue
while the Flutter UI is suspended. **Swiping the app away cancels iOS background
transfers and prevents automatic relaunch until the app is opened again.**

The Mac must be awake/reachable and the destination mounted. Permission
restrictions, Low Power Mode, and access before the first unlock after reboot
can delay work. Queued or waiting work is not reported as a completed backup.

Update the server for recoverable native backup support
(`capabilities.backgroundBackupTus = 1` from `/api/health`). Older servers retain
foreground-upload compatibility. See [backup behavior](docs/notifications-backup.md)
and [the API contract](docs/api-integration.md).

## Development and installation

Requires the Flutter/Dart version supported by `pubspec.yaml`, Android 8.0+
(API 26), or iOS 15+. This development Mac uses Xcode 16.4 and pinned compatible
plugins. Android compile SDK stays pinned to 36.

On this host, source the configured environment before Flutter commands:

```bash
source ~/.localdrive_flutter_env.sh && flutter pub get
source ~/.localdrive_flutter_env.sh && flutter analyze
source ~/.localdrive_flutter_env.sh && flutter test
source ~/.localdrive_flutter_env.sh && flutter build apk --release --split-per-abi --target-platform android-arm64
source ~/.localdrive_flutter_env.sh && flutter build ios --release
```

The Android release template uses debug signing for local installation, not Play
Store distribution. iPhone installation needs valid signing and a trusted
physical device. Update apps in place to retain their data; do not uninstall or
reset the database as a backup-error workaround.

See [build and device-install instructions](docs/build-run.md), including
resource-constrained Android builds and the distinction between Xcode and
Flutter iOS output paths.

## Documentation

Start with the [knowledge base](docs/README.md), then
[architecture](docs/architecture.md), [state management](docs/state-management.md),
and [permissions](docs/permissions.md).
The [Copilot working brief](.github/copilot-instructions.md) captures the
cross-account, storage, and server-compatibility invariants.
