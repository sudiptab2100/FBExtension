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

  group('LdInstance addresses + candidates', () {
    test('allHosts dedupes and orders IPv4 before .local', () {
      const i = LdInstance(
        scheme: 'http',
        host: '192.168.1.20',
        port: 4820,
        name: 'mac',
        source: InstanceSource.discovered,
        hostname: 'mac.local',
        addresses: ['mac.local', '192.168.1.20', '10.0.0.9'],
      );
      // Dedupes host/addresses; .local sorts after IPv4.
      expect(i.allHosts, ['192.168.1.20', '10.0.0.9', 'mac.local']);
      expect(i.addressSummary, '192.168.1.20 · 10.0.0.9 · mac.local');
    });

    test('addresses + httpsPort survive JSON + copyWith', () {
      const i = LdInstance(
        scheme: 'http',
        host: '192.168.1.20',
        port: 4820,
        name: 'mac',
        source: InstanceSource.discovered,
        addresses: ['192.168.1.20', 'mac.local'],
        httpsPort: 4843,
      );
      final restored = LdInstance.fromJson(i.toJson());
      expect(restored.addresses, ['192.168.1.20', 'mac.local']);
      expect(restored.httpsPort, 4843);
      expect(restored.hasHttps, isTrue);
      expect(i.copyWith(name: 'x').addresses, i.addresses);
    });

    test('orderedCandidates tries current endpoint, then HTTPS, then hosts', () {
      const i = LdInstance(
        scheme: 'http',
        host: '192.168.1.20',
        port: 4820,
        name: 'mac',
        source: InstanceSource.discovered,
        addresses: ['192.168.1.20', 'mac.local'],
        httpsPort: 4843,
      );
      final ids = i.orderedCandidates().map((c) => c.id).toList();
      expect(ids, [
        'http://192.168.1.20:4820', // the exact endpoint first
        'https://192.168.1.20:4843', // HTTPS on IP
        'https://mac.local:4843', // HTTPS on .local
        'http://mac.local:4820', // HTTP on .local
      ]);
    });

    test('bare HTTPS instance never invents HTTP on the HTTPS port', () {
      // A QR-scanned https URL with no advertised httpsPort → only itself.
      final i = LdInstance.tryParse('https://192.168.1.20:4843')!;
      final ids = i.orderedCandidates().map((c) => c.id).toList();
      expect(ids, ['https://192.168.1.20:4843']);
    });
  });
}
