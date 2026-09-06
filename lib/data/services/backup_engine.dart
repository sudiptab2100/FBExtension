import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/constants.dart';
import '../../core/storage/local_db.dart';
import '../models/backup_settings.dart';
import '../models/ld_instance.dart';
import 'media_service.dart';
import 'notification_service.dart';
import 'upload_service.dart';

/// Outcome of a backup pass.
class BackupResult {
  const BackupResult({
    this.uploaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.error,
  });

  final int uploaded;
  final int skipped;
  final int failed;
  final String? error;
}

/// Live progress callback: cumulative counts plus the current item name.
typedef BackupProgress = void Function(
    int uploaded, int skipped, int failed, String? current);

/// Enumerates enabled sources, dedupes against the local ledger, and uploads
/// new items via tus. Pure of Riverpod so it runs in both the UI isolate
/// (manual "back up now") and the WorkManager background isolate.
class BackupEngine {
  BackupEngine({
    required this.instanceId,
    required this.settings,
    required this.media,
    required this.upload,
    required this.db,
    this.onProgress,
  });

  final String instanceId;
  final BackupSettings settings;
  final MediaService media;
  final UploadService upload;
  final LocalDb db;
  final BackupProgress? onProgress;

  int _uploaded = 0;
  int _skipped = 0;
  int _failed = 0;

  static String _join(String a, String b) => a.isEmpty ? b : '$a/$b';

  Future<BackupResult> run() async {
    try {
      if (settings.photos || settings.videos) {
        await _backupGallery();
      }
      if (settings.contacts) {
        await _backupContacts();
      }
      return BackupResult(
        uploaded: _uploaded,
        skipped: _skipped,
        failed: _failed,
      );
    } catch (e) {
      return BackupResult(
        uploaded: _uploaded,
        skipped: _skipped,
        failed: _failed,
        error: e.toString(),
      );
    }
  }

  Future<void> _backupGallery() async {
    final granted = await media.requestGalleryAccess();
    if (!granted) return;

    final type = (settings.photos && settings.videos)
        ? RequestType.common
        : (settings.photos ? RequestType.image : RequestType.video);

    final albums = await media.albums(type: type);
    if (albums.isEmpty) return;
    final all = albums.firstWhereOrNull((a) => a.isAll) ?? albums.first;

    var page = 0;
    while (true) {
      final batch = await media.assets(all, page: page, pageSize: 100);
      if (batch.isEmpty) break;
      for (final a in batch) {
        if (a.type == AssetType.image && !settings.photos) continue;
        if (a.type == AssetType.video && !settings.videos) continue;

        if (await db.isBackedUp(instanceId, a.id)) {
          _skipped++;
          _report(null);
          continue;
        }
        final file = await a.file;
        if (file == null) {
          _failed++;
          _report(null);
          continue;
        }
        final title = await a.titleAsync;
        final name = title.isNotEmpty ? title : file.uri.pathSegments.last;
        final sub = a.type == AssetType.video ? 'Videos' : 'Photos';
        final dest = _join(settings.folder, sub);
        _report(name);
        try {
          await upload.upload(
            file: XFile(file.path, name: name),
            drive: settings.driveUuid!,
            destPath: dest,
          );
          await db.markBackedUp(
            instanceId: instanceId,
            assetId: a.id,
            name: name,
            size: await file.length(),
            remoteDrive: settings.driveUuid,
            remotePath: _join(dest, name),
          );
          _uploaded++;
        } catch (_) {
          _failed++;
        }
        _report(null);
      }
      page++;
    }
  }

  Future<void> _backupContacts() async {
    final granted = await media.requestContactsAccess();
    if (!granted) return;

    // Dedupe contacts to once per calendar day.
    final day = DateTime.now().toIso8601String().split('T').first;
    final assetId = 'contacts-$day';
    if (await db.isBackedUp(instanceId, assetId)) {
      _skipped++;
      return;
    }

    final count = await media.contactsCount();
    if (count == 0) return;

    _report('Contacts');
    try {
      final vcf = await media.exportContactsVcf();
      final dest = _join(settings.folder, 'Contacts');
      await upload.upload(
        file: vcf,
        drive: settings.driveUuid!,
        destPath: dest,
      );
      await db.markBackedUp(
        instanceId: instanceId,
        assetId: assetId,
        name: vcf.name,
        remoteDrive: settings.driveUuid,
        remotePath: _join(dest, vcf.name),
      );
      _uploaded++;
    } catch (_) {
      _failed++;
    }
    _report(null);
  }

  void _report(String? current) =>
      onProgress?.call(_uploaded, _skipped, _failed, current);
}

/// Headless backup for the WorkManager background isolate. Reads persisted
/// settings + the active instance's token directly (no Riverpod) and posts a
/// completion notification. No-ops unless auto-backup is fully configured.
Future<void> runHeadlessBackup() async {
  final prefs = await SharedPreferences.getInstance();
  final settingsRaw = prefs.getString(StoreKeys.backupSettings);
  if (settingsRaw == null) return;

  BackupSettings settings;
  try {
    settings = BackupSettings.fromJson(
        jsonDecode(settingsRaw) as Map<String, dynamic>);
  } catch (_) {
    return;
  }
  if (!settings.runnable) return;

  final activeId = prefs.getString(StoreKeys.activeInstanceId);
  final instancesRaw = prefs.getString(StoreKeys.savedInstances);
  if (activeId == null || instancesRaw == null) return;

  final LdInstance? inst;
  try {
    inst = (jsonDecode(instancesRaw) as List)
        .map((e) => LdInstance.fromJson(e as Map<String, dynamic>))
        .firstWhereOrNull((i) => i.id == activeId);
  } catch (_) {
    return;
  }
  if (inst == null) return;

  const secure = FlutterSecureStorage();
  final token = await secure.read(key: '${StoreKeys.tokenPrefix}${inst.id}');
  if (token == null || token.isEmpty) return;

  final upload = UploadService(
    baseUrl: inst.baseUrl,
    trustSelfSigned: inst.trustSelfSigned,
    headers: {
      'Authorization': 'Bearer $token',
      'Cookie': '${ViewCookie.name}=${ViewCookie.user}',
    },
  );
  final db = await LocalDb.open();
  final engine = BackupEngine(
    instanceId: inst.id,
    settings: settings,
    media: const MediaService(),
    upload: upload,
    db: db,
  );
  final res = await engine.run();

  if (res.uploaded > 0 && (prefs.getBool(SettingKeys.notificationsEnabled) ?? true)) {
    final notif = NotificationService.instance;
    await notif.init();
    await notif.post(
      title: 'Backup complete',
      body: '${res.uploaded} item(s) backed up to ${inst.name}',
      channelId: Notif.backupChannelId,
      channelName: Notif.backupChannelName,
    );
  }
}
