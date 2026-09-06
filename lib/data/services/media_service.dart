import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

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
      out.add(XFile(
        f.path,
        name: title.isNotEmpty ? title : p.basename(f.path),
      ));
    }
    return out;
  }

  // ---- Contacts -----------------------------------------------------------

  /// Requests read access to contacts.
  Future<bool> requestContactsAccess() async {
    final status =
        await FlutterContacts.permissions.request(PermissionType.read);
    return status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
  }

  /// Number of contacts available (for a summary before exporting).
  Future<int> contactsCount() async {
    final contacts =
        await FlutterContacts.getAll(properties: ContactProperties.none);
    return contacts.length;
  }

  /// Exports every contact into one `.vcf` document and returns it as an
  /// [XFile] (written to a temp dir) ready for upload.
  Future<XFile> exportContactsVcf() async {
    final contacts =
        await FlutterContacts.getAll(properties: ContactProperties.allProperties);
    final vcf = FlutterContacts.vCard.exportAll(contacts);
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final name = 'contacts-$stamp.vcf';
    final file = File(p.join(dir.path, name));
    await file.writeAsString(vcf);
    return XFile(file.path, name: name);
  }
}

final mediaServiceProvider = Provider<MediaService>((_) => const MediaService());
