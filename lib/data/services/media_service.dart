import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/backup_job.dart';

/// On-device media (photos/videos) and contacts access, plus helpers that turn
/// them into [XFile]s ready for upload through the tus `UploadService`.
class MediaService {
  const MediaService();

  // ---- Photos & videos ----------------------------------------------------

  /// Requests photo-library access; returns whether assets are readable.
  Future<bool> requestGalleryAccess() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  /// Checks existing grants only; safe in a WorkManager/headless engine.
  Future<bool> hasGalleryAccess({
    bool photos = true,
    bool videos = true,
  }) async {
    final type = photos && videos
        ? RequestType.common
        : (photos ? RequestType.image : RequestType.video);
    final state = await PhotoManager.getPermissionState(
      requestOption: PermissionRequestOption(
        androidPermission: AndroidPermission(type: type, mediaLocation: false),
      ),
    ).timeout(const Duration(seconds: 10));
    return state.hasAccess;
  }

  /// A bounded page from the system's all-assets album, not an exported gallery.
  Future<List<AssetEntity>> backupAssets({
    required bool photos,
    required bool videos,
    required int start,
    int count = 40,
  }) async {
    final type = photos && videos
        ? RequestType.common
        : (photos ? RequestType.image : RequestType.video);
    final all = await PhotoManager.getAssetPathList(
      type: type,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: true),
        ],
      ),
    ).timeout(const Duration(seconds: 10));
    if (all.isEmpty) return [];
    final album = all.first;
    final total = await album.assetCountAsync.timeout(
      const Duration(seconds: 10),
    );
    if (start >= total) return [];
    return album
        .getAssetListRange(start: start, end: (start + count).clamp(0, total))
        .timeout(const Duration(seconds: 10));
  }

  Future<AssetEntity?> backupAsset(String id) =>
      AssetEntity.fromId(id).timeout(const Duration(seconds: 10));

  Future<String> backupAssetName(AssetEntity asset, File file) async {
    final name = await asset.titleAsync.timeout(const Duration(seconds: 10));
    return name.isEmpty ? p.basename(file.path) : p.basename(name);
  }

  /// Do not start an unbounded iCloud download during a processing wake.
  Future<File> backupFile(AssetEntity asset) async {
    if ((Platform.isIOS || Platform.isMacOS) &&
        !await asset
            .isLocallyAvailable(isOrigin: true)
            .timeout(const Duration(seconds: 5))) {
      throw BackupFailure(
        'Some photos or videos are in iCloud. Download their originals and retry.',
        code: 'media_cloud',
        waiting: true,
      );
    }
    final token = PMCancelToken();
    File? file;
    try {
      file = await asset
          .loadFile(isOrigin: true, cancelToken: token)
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      if (Platform.isIOS || Platform.isMacOS) {
        await token.cancelRequest().timeout(const Duration(seconds: 3));
      }
      throw BackupFailure(
        'A media original is not available yet. Open Photos and retry later.',
        code: 'media_timeout',
        waiting: true,
      );
    }
    if (file == null) {
      throw BackupFailure(
        'A media original is unavailable. Open Photos and retry later.',
        code: 'media_missing',
        waiting: true,
      );
    }
    return file;
  }

  /// Albums for [type] (default: images + videos), including the "all" album.
  Future<List<AssetPathEntity>> albums({
    RequestType type = RequestType.common,
  }) {
    return PhotoManager.getAssetPathList(
      type: type,
      hasAll: true,
      onlyAll: false,
    );
  }

  /// A page of assets in [album].
  Future<List<AssetEntity>> assets(
    AssetPathEntity album, {
    int page = 0,
    int pageSize = 60,
  }) {
    return album.getAssetListPaged(page: page, size: pageSize);
  }

  /// Resolves selected [entities] to on-disk [XFile]s, skipping any that fail
  /// to materialise (e.g. iCloud assets still downloading).
  Future<List<XFile>> filesFor(Iterable<AssetEntity> entities) async {
    final out = <XFile>[];
    for (final a in entities) {
      final f = await a.file;
      if (f == null) continue;
      final title = await a.titleAsync;
      out.add(
        XFile(f.path, name: title.isNotEmpty ? title : p.basename(f.path)),
      );
    }
    return out;
  }

  // ---- Contacts -----------------------------------------------------------

  /// Requests read access to contacts.
  Future<bool> requestContactsAccess() async {
    final status = await FlutterContacts.permissions.request(
      PermissionType.read,
    );
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
  }

  Future<bool> hasContactsAccess() async {
    final status = await FlutterContacts.permissions
        .check(PermissionType.read)
        .timeout(const Duration(seconds: 10));
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
  }

  /// Checkpoint a daily vCard in owned staging. Only one contact's properties
  /// are loaded at a time; a short processing wake can resume the same export.
  Future<int> exportBackupContacts(
    Directory directory, {
    required Future<void> Function() checkpoint,
    int? maximumBytes,
  }) async {
    final idsFile = File(p.join(directory.path, 'contacts.ids'));
    final cursorFile = File(p.join(directory.path, 'contacts.cursor'));
    final outputFile = File(p.join(directory.path, 'contacts.export'));
    for (final file in [idsFile, cursorFile, outputFile]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Refusing a symbolic link in contacts staging.');
      }
    }
    if (!await idsFile.exists()) {
      final contacts = await FlutterContacts.getAll(
        properties: ContactProperties.none,
      ).timeout(const Duration(seconds: 15));
      final ids = contacts
          .map((contact) => contact.id)
          .whereType<String>()
          .toList();
      final partial = File('${idsFile.path}.part');
      await partial.writeAsString(jsonEncode(ids), flush: true);
      await partial.rename(idsFile.path);
    }
    final ids = (jsonDecode(await idsFile.readAsString()) as List)
        .cast<String>();
    var index = 0;
    var bytes = 0;
    var written = 0;
    if (await cursorFile.exists()) {
      final cursor = jsonDecode(await cursorFile.readAsString()) as Map;
      index = cursor['index'] as int;
      bytes = cursor['bytes'] as int;
      written = cursor['written'] as int;
    }
    if (index < 0 || index > ids.length || bytes < 0) {
      throw const FormatException('Invalid contacts export checkpoint.');
    }
    final output = await outputFile.open(mode: FileMode.append);
    if (await output.length() < bytes) {
      await output.close();
      throw const FormatException(
        'Contacts export is shorter than its checkpoint.',
      );
    }
    await output.truncate(bytes);
    await output.setPosition(bytes);
    try {
      while (index < ids.length) {
        await checkpoint();
        final contact = await FlutterContacts.get(
          ids[index],
          properties: ContactProperties.allProperties,
        ).timeout(const Duration(seconds: 10));
        if (contact != null) {
          final vcard = utf8.encode(
            '${FlutterContacts.vCard.export(contact)}\r\n',
          );
          if (maximumBytes != null && bytes + vcard.length > maximumBytes) {
            throw BackupFailure(
              'Waiting for staging space to continue the contacts backup.',
              code: 'staging_budget',
              waiting: true,
            );
          }
          await output.writeFrom(vcard);
          bytes += vcard.length;
          written++;
        }
        index++;
        if (index % 10 == 0 || index == ids.length) {
          await output.flush();
          final partial = File('${cursorFile.path}.part');
          await partial.writeAsString(
            jsonEncode({'index': index, 'bytes': bytes, 'written': written}),
            flush: true,
          );
          await partial.rename(cursorFile.path);
        }
      }
    } finally {
      await output.close();
    }
    return written;
  }

  /// Number of contacts available (for a summary before exporting).
  Future<int> contactsCount() async {
    final contacts = await FlutterContacts.getAll(
      properties: ContactProperties.none,
    );
    return contacts.length;
  }

  /// Exports every contact into one `.vcf` document and returns it as an
  /// [XFile] (written to a temp dir) ready for upload.
  Future<XFile> exportContactsVcf() async {
    final contacts = await FlutterContacts.getAll(
      properties: ContactProperties.allProperties,
    );
    final vcf = FlutterContacts.vCard.exportAll(contacts);
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final name = 'contacts-$stamp.vcf';
    final file = File(p.join(dir.path, name));
    await file.writeAsString(vcf);
    return XFile(file.path, name: name);
  }
}

final mediaServiceProvider = Provider<MediaService>(
  (_) => const MediaService(),
);
