import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/utils/format.dart';
import 'package:localdrive_app/data/repositories/files_repository.dart';

void main() {
  group('formatBytes', () {
    test('handles zero, null and units', () {
      expect(formatBytes(null), '—');
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1048576), '1.0 MB');
    });
  });

  group('FilesRepository URL builders', () {
    final repo =
        FilesRepository(Dio(BaseOptions(baseUrl: 'http://host.local:4820')));

    test('rawUrl encodes drive and path', () {
      final u = repo.rawUrl('DRIVE-1', '/a/b c.jpg');
      expect(u.path, '/api/files/raw');
      expect(u.queryParameters['drive'], 'DRIVE-1');
      expect(u.queryParameters['path'], '/a/b c.jpg');
      expect(u.host, 'host.local');
      expect(u.port, 4820);
    });

    test('thumbUrl includes size', () {
      final u = repo.thumbUrl('D', '/x.png', size: 256);
      expect(u.path, '/api/files/thumb');
      expect(u.queryParameters['size'], '256');
    });

    test('zipUrl joins paths with newlines', () {
      final u = repo.zipUrl('D', ['/a', '/b']);
      expect(u.path, '/api/files/zip');
      expect(u.queryParameters['paths'], '/a\n/b');
    });

    test('downloadUrl targets the download endpoint', () {
      final u = repo.downloadUrl('D', '/file.bin');
      expect(u.path, '/api/files/download');
      expect(u.queryParameters['path'], '/file.bin');
    });
  });
}
