import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';

void main() {
  group('LdInstance.tryParse', () {
    test('bare host defaults to http:4820', () {
      final i = LdInstance.tryParse('192.168.1.20')!;
      expect(i.scheme, 'http');
      expect(i.host, '192.168.1.20');
      expect(i.port, 4820);
      expect(i.baseUrl, 'http://192.168.1.20:4820');
      expect(i.id, 'http://192.168.1.20:4820');
    });

    test('explicit https URL keeps scheme and port', () {
      final i = LdInstance.tryParse('https://mac.local:4843')!;
      expect(i.scheme, 'https');
      expect(i.host, 'mac.local');
      expect(i.port, 4843);
      expect(i.isHttps, isTrue);
      expect(i.hostname, 'mac.local');
    });

    test('https without a port defaults to 4843', () {
      final i = LdInstance.tryParse('https://10.0.0.5')!;
      expect(i.port, 4843);
    });

    test('host:port without scheme assumes http', () {
      final i = LdInstance.tryParse('nas.local:8080')!;
      expect(i.scheme, 'http');
      expect(i.port, 8080);
      expect(i.host, 'nas.local');
    });

    test('blank input returns null', () {
      expect(LdInstance.tryParse('   '), isNull);
      expect(LdInstance.tryParse(''), isNull);
    });

    test('round-trips through JSON', () {
      final i = LdInstance.tryParse('https://mac.local:4843',
          name: 'My Mac', source: InstanceSource.qr)!;
      final restored = LdInstance.fromJson(i.toJson());
      expect(restored.id, i.id);
      expect(restored.name, 'My Mac');
      expect(restored.source, InstanceSource.qr);
      expect(restored.scheme, 'https');
    });
  });
}
